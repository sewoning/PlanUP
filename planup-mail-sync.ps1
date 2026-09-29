#Requires -Version 5.1
<#
  PlanUP 메일 동기화 — 당일 아웃룩 메일의 "헤더"만 PlanUP으로 올린다.

  아웃룩 PST는 내 PC 안의 파일이라 웹앱이 직접 읽을 수 없다. 그래서 이 스크립트가
  로컬에서 아웃룩을 읽고 PlanUP(Supabase)에 올리는 역할을 한다.

  올리는 것   : 제목 · 보낸사람 · 받는사람 · 시각 · 폴더 · 첨부파일명 · 본문 앞 200자
  올리지 않는 것: 본문 전체, 첨부파일 내용

  쓰는 법
    # 올리지 않고 뭐가 뽑히는지만 확인
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -Preview

    # 한 번 올리기 (닉네임/비밀번호는 PlanUP 로그인과 동일)
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -Nickname sewoning

    # 30분마다 자동으로 (한 번만 등록해두면 끝)
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -InstallTask -Nickname sewoning

    # 자동 실행 해제 / 저장된 비밀번호 삭제
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -Uninstall
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -Forget
#>
param(
  [string]$Nickname,
  [string]$Password,
  [int]$Days = 1,              # 1 = 당일만
  [switch]$Preview,            # 올리지 않고 결과만 보기
  [switch]$InstallTask,        # 작업 스케줄러에 등록만 하고 종료
  [switch]$Uninstall,          # 등록 해제
  [switch]$Forget,             # 저장된 비밀번호 삭제
  [int]$EveryMinutes = 30      # 자동 실행 주기
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SUPABASE_URL = 'https://awtdpyoiecymhnwjvtki.supabase.co'
$SUPABASE_ANON_KEY = 'sb_publishable_GgvVhU2ecDXearjojyz-6Q_Yxlnp-TB'
$TASK_NAME = 'PlanUP 메일 동기화'

# 새로 온 내용만 담고, 아래에 인용되어 딸려오는 이전 메일들은 걷어낸다.
# 답장이 오갈수록 같은 내용이 계속 불어나서(실측 13만 자짜리 스레드도 있었다) 용량 대부분을
# 차지하는데, 정작 읽고 싶은 건 맨 위 새 내용뿐이다. 실측으로 174만 자 → 13만 자(93% 감소).
$BodyCap = 8000   # 뉴스레터처럼 유난히 긴 것에 대비한 안전장치 (평소엔 걸리지 않는다)

# ── 비밀번호 보관 ─────────────────────────────────────────────────
# 무인 실행을 하려면 비밀번호가 어딘가 있어야 한다. DPAPI로 암호화해서 두면
# "이 PC의 이 윈도우 계정"에서만 풀린다 — 파일을 복사해가도 남의 PC에선 못 읽는다.
# 저장 위치는 프로젝트 폴더가 아니라 개인 앱 데이터 폴더 (깃에 딸려 올라가지 않게).
$CredDir  = Join-Path $env:LOCALAPPDATA 'PlanUP'
$CredFile = Join-Path $CredDir 'mail-cred.xml'

function Save-Cred([string]$nick, [string]$pw) {
  if (-not (Test-Path $CredDir)) { New-Item -ItemType Directory -Path $CredDir -Force | Out-Null }
  @{
    nickname = $nick
    secret   = (ConvertTo-SecureString $pw -AsPlainText -Force | ConvertFrom-SecureString)
  } | Export-Clixml -Path $CredFile
}

function Get-SavedCred {
  if (-not (Test-Path $CredFile)) { return $null }
  try {
    $c = Import-Clixml -Path $CredFile
    $sec = ConvertTo-SecureString $c.secret
    @{
      nickname = $c.nickname
      password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                   [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
  } catch { $null }   # 다른 계정/PC로 옮겨졌으면 복호화가 안 된다
}

if ($Forget) {
  if (Test-Path $CredFile) { Remove-Item $CredFile -Force; Write-Host "저장된 비밀번호를 지웠어요." -ForegroundColor Green }
  else { Write-Host "저장된 비밀번호가 없어요." }
  return
}

if ($Uninstall) {
  # 설치 방식이 두 가지(작업 스케줄러 / 시작프로그램)라 양쪽 다 치운다
  $done = @()
  try { Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop; $done += '작업 스케줄러' } catch {}

  $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'PlanUP 메일 동기화.vbs'
  if (Test-Path $vbs) { Remove-Item $vbs -Force; $done += '시작프로그램' }

  # 지금 돌고 있는 반복 실행기도 멈춘다
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*loop.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force; $done += '실행 중이던 프로세스' } catch {} }

  if ($done) { Write-Host ("자동 실행을 해제했어요 — " + ($done -join ', ')) -ForegroundColor Green }
  else { Write-Host "등록된 자동 실행이 없어요." }
  return
}

# ── 작업 스케줄러 등록 ────────────────────────────────────────────
if ($InstallTask) {
  # 바로가기(.bat)로 더블클릭해서 들어오는 경우엔 인자가 없으므로 여기서 물어본다
  if (-not $Nickname) { $Nickname = (Read-Host 'PlanUP 닉네임').Trim() }
  if (-not $Nickname) { throw '닉네임이 필요해요' }

  # 등록 시점에 비밀번호를 한 번 받아 암호화해 둔다. 이후로는 안 물어본다.
  if (-not $Password) {
    $sec = Read-Host "PlanUP 비밀번호 ($Nickname)" -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  }
  Save-Cred $Nickname $Password

  $self = $MyInvocation.MyCommand.Path

  # 작업 스케줄러가 제일 깔끔하지만 등록에 관리자 권한이 필요하다. 회사 PC라 권한이
  # 없는 경우가 많아서, 막히면 시작프로그램 폴더로 자동으로 넘어간다.
  # CIM 기반 cmdlet은 $ErrorActionPreference='Stop'을 무시하고 넘어가는 일이 있어서,
  # 예외에만 기대지 않고 "작업이 실제로 등록됐는지"를 확인한 뒤에만 성공으로 친다.
  $installed = 'startup'
  try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$self`""

    # 로그온하면 시작해서 N분마다 반복. 기간을 아주 길게 줘서 사실상 무기한으로 둔다.
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
      -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
      -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition

    # 아웃룩이 느릴 때가 있어서, 앞 회차가 아직 돌고 있으면 이번 회차는 건너뛴다
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
      -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 25) `
      -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger `
      -Settings $settings -Description '당일 아웃룩 메일 헤더를 PlanUP으로 올립니다' `
      -Force -ErrorAction Stop 2>$null | Out-Null
    if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) {
      Start-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
      $installed = 'task'
    }
  } catch {
    $installed = 'startup'   # 대개 관리자 권한 없음 (HRESULT 0x80070005)
  }

  if ($installed -eq 'startup') {
    # 작업 스케줄러를 못 쓰니, 로그인할 때 뜨는 숨은 프로세스가 직접 주기를 센다.
    $loopPs  = Join-Path $CredDir 'loop.ps1'
    $logFile = Join-Path $CredDir 'sync.log'
    $secs = $EveryMinutes * 60

    $loopBody = @"
# PlanUP 메일 동기화 반복 실행기 (작업 스케줄러 권한이 없을 때 쓰는 대안).
# 같은 게 두 번 뜨지 않도록 뮤텍스로 한 번에 하나만 돌게 막는다.
`$mutex = New-Object System.Threading.Mutex(`$false, 'PlanUPMailSyncLoop')
if (-not `$mutex.WaitOne(0)) { return }
try {
  while (`$true) {
    `$ts = Get-Date -Format 'yyyy-MM-dd HH:mm'
    try { `$out = & '$self' 2>&1 | Out-String } catch { `$out = `$_.Exception.Message }
    "[`$ts] `$(`$out.Trim())" | Add-Content -Path '$logFile' -Encoding UTF8
    # 로그가 계속 자라지 않게 최근 것만 남긴다
    if ((Get-Item '$logFile').Length -gt 200KB) {
      Get-Content '$logFile' -Tail 100 | Set-Content '$logFile' -Encoding UTF8
    }
    Start-Sleep -Seconds $secs
  }
} finally { `$mutex.ReleaseMutex() }
"@
    [System.IO.File]::WriteAllText($loopPs, $loopBody, (New-Object System.Text.UTF8Encoding $true))

    # 검은 창이 뜨지 않게 VBS로 숨겨서 띄운다
    $startup = [Environment]::GetFolderPath('Startup')
    $vbs = Join-Path $startup 'PlanUP 메일 동기화.vbs'
    $vbsBody = "CreateObject(""WScript.Shell"").Run ""powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$loopPs"""""", 0, False"
    [System.IO.File]::WriteAllText($vbs, $vbsBody, [System.Text.Encoding]::Unicode)

    # 지금 바로 돌기 시작
    Start-Process 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
  }

  Write-Host ""
  if ($installed -eq 'task') {
    Write-Host "등록 완료 — 작업 스케줄러로 $EveryMinutes 분마다 올라가요." -ForegroundColor Green
  } else {
    Write-Host "등록 완료 — $EveryMinutes 분마다 올라가요." -ForegroundColor Green
    Write-Host "(이 PC에 작업 스케줄러 등록 권한이 없어서 시작프로그램 방식으로 넣었어요)" -ForegroundColor Gray
    Write-Host "기록: $(Join-Path $CredDir 'sync.log')" -ForegroundColor Gray
  }
  Write-Host "비밀번호는 이 PC의 이 계정에서만 풀리게 암호화해서 보관했어요:" -ForegroundColor Gray
  Write-Host "  $CredFile" -ForegroundColor Gray
  Write-Host ""
  Write-Host "지금 첫 회차가 돌고 있어요. 잠시 뒤 PlanUP 메일 탭을 새로고침해보세요." -ForegroundColor Cyan
  return
}

# ── 아웃룩에서 읽기 ───────────────────────────────────────────────
function Clean([string]$s) {
  if (-not $s) { return "" }
  ($s -replace '\s+', ' ').Trim()
}

# 인용된 이전 메일이 시작되는 지점을 찾는다.
# 아웃룩 답장은 구분선 없이 "From:" 줄 바로 다음에 "Sent:"가 오는 헤더 블록으로 시작하는 게
# 가장 흔하다. 이 "두 줄 연속" 조합이라야 본문에 우연히 섞인 From: 한 줄에 안 속는다.
$QuoteMarkers = @(
  '-{2,}\s*(원본 메시지|Original Message)\s*-{2,}',
  '(?m)^[ \t>]*(From|보낸\s?사람)\s*:.*\r?\n[ \t>]*(Sent|보낸\s?날짜)\s*:',
  '(?m)^[ \t>]*(보낸\s?사람|From)\s*:.*\r?\n[ \t>]*(받는\s?사람|To)\s*:',
  '(?m)^[ \t]*[_-]{10,}[ \t]*\r?\n(?:[ \t]*\r?\n){0,3}[ \t]*(보낸\s?사람|From)\s*:',
  '(?m)^.{0,100}(님이 작성했습니다|wrote:)[ \t]*$'
)

function Get-NewBody([string]$raw) {
  if (-not $raw) { return "" }
  $at = $raw.Length
  foreach ($r in $QuoteMarkers) {
    $mm = [regex]::Match($raw, $r)
    if ($mm.Success -and $mm.Index -lt $at) { $at = $mm.Index }
  }
  # 맨 앞에서 잘렸다면 전달(Fwd)처럼 인용이 곧 본문인 경우다 — 그땐 자르지 않는다
  if ($at -lt 120) { $at = $raw.Length }
  $b = $raw.Substring(0, $at).Trim()
  if ($b.Length -gt $BodyCap) { $b = $b.Substring(0, $BodyCap).TrimEnd() + "`n…(이후 생략)" }
  # 줄바꿈은 살리되, 빈 줄이 우르르 이어지는 건 줄인다 (아웃룩 본문에 흔하다)
  ($b -replace '[ \t]+\r?\n', "`n") -replace '(\r?\n){3,}', "`n`n"
}

Write-Host "아웃룩에서 읽는 중..." -ForegroundColor Cyan
$ol = New-Object -ComObject Outlook.Application
$ns = $ol.GetNamespace("MAPI")

# "당일"은 오늘 0시부터. -Days 2면 어제 0시부터.
$since = (Get-Date).Date.AddDays(-($Days - 1))
$sinceStr = $since.ToString("MM/dd/yyyy HH:mm")
$items = @()

foreach ($store in $ns.Folders) {
  foreach ($folderName in @("받은 편지함", "보낸 편지함")) {
    try { $folder = $store.Folders.Item($folderName) } catch { continue }

    $isSent = ($folderName -eq "보낸 편지함")
    $dateProp = if ($isSent) { "[SentOn]" } else { "[ReceivedTime]" }

    try { $filtered = $folder.Items.Restrict("$dateProp >= '$sinceStr'") } catch { continue }
    if ($filtered.Count -eq 0) { continue }
    Write-Host ("  {0} / {1}: {2}건" -f $store.Name, $folderName, $filtered.Count)

    # 큰 폴더는 인덱스 접근이 느려서 GetFirst/GetNext로 훑는다
    $m = $filtered.GetFirst()
    while ($m) {
      try {
        if ($m.Class -eq 43) {   # olMail만 (회의 요청·수신확인 등 제외)
          $when = if ($isSent) { $m.SentOn } else { $m.ReceivedTime }

          $atts = @()
          if ($m.Attachments.Count -gt 0) {
            foreach ($a in $m.Attachments) {
              # 서명에 박힌 로고 같은 인라인 이미지는 첨부로 치지 않는다
              if ($a.FileName -notmatch '^(image\d+\.(png|jpg|jpeg|gif)|~)') { $atts += $a.FileName }
            }
          }

          $body = Get-NewBody $m.Body

          $items += [ordered]@{
            entry_id    = $m.EntryID
            direction   = $(if ($isSent) { "sent" } else { "received" })
            subject     = Clean $m.Subject
            from_name   = Clean $m.SenderName
            from_email  = Clean $m.SenderEmailAddress
            to_line     = Clean $m.To
            sent_at     = $when.ToString("yyyy-MM-ddTHH:mm:sszzz")
            folder      = "$($store.Name)/$folderName"
            has_attach  = ($atts.Count -gt 0)
            attachments = @($atts)
            body        = $body
            unread      = [bool]$m.UnRead
          }
        }
      } catch { }
      $m = $filtered.GetNext()
    }
  }
}

Write-Host ""
Write-Host ("메일 {0}건 (최근 {1}일)" -f $items.Count, $Days) -ForegroundColor Green

# 스케줄러가 부를 땐 인자 없이 돌아오므로, 저장해둔 계정을 쓴다.
# 저장된 게 없고 사람이 직접 돌린 거면 물어본다 (.bat 더블클릭한 경우).
if (-not $Nickname -and -not $Preview) {
  $saved = Get-SavedCred
  if ($saved) {
    $Nickname = $saved.nickname
    $Password = $saved.password
  } elseif ([Environment]::UserInteractive) {
    $Nickname = (Read-Host 'PlanUP 닉네임').Trim()
  }
}

if ($Preview -or -not $Nickname) {
  $out = Join-Path $PSScriptRoot "mail_preview.json"
  $json = $items | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding $false))
  Write-Host ("미리보기 저장: {0} ({1} KB)" -f $out, [math]::Round((Get-Item $out).Length / 1KB, 1))
  if (-not $Nickname) { Write-Host "올리려면 -Nickname 을 넣어주세요." -ForegroundColor Yellow }
  return
}

# ── PlanUP 로그인 ────────────────────────────────────────────────
if (-not $Password) {
  $saved = Get-SavedCred
  if ($saved -and $saved.nickname -eq $Nickname) {
    $Password = $saved.password
  } else {
    $sec = Read-Host "PlanUP 비밀번호 ($Nickname)" -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    Save-Cred $Nickname $Password   # 다음부터는 안 물어보게
  }
}

# 앱과 똑같은 규칙으로 닉네임을 내부 이메일로 바꾼다 (index.html의 nicknameToEmail)
$clean = $Nickname.Trim().ToLower()
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
$email = "u$b64@planup.local"

Write-Host "PlanUP 로그인 중..." -ForegroundColor Cyan
try {
  $auth = Invoke-RestMethod -Method Post `
    -Uri "$SUPABASE_URL/auth/v1/token?grant_type=password" `
    -Headers @{ apikey = $SUPABASE_ANON_KEY; 'Content-Type' = 'application/json' } `
    -Body (@{ email = $email; password = $Password } | ConvertTo-Json)
} catch {
  # 자동 실행일 땐 이 메시지만 로그에 남으므로, 뭘 해야 하는지까지 적어준다
  $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
  if ($code -eq 400) {
    throw "로그인 실패 — 닉네임($Nickname) 또는 비밀번호가 맞지 않아요. " +
          "'메일 자동연동 설정.bat'을 다시 실행해서 비밀번호를 새로 넣어주세요."
  }
  throw "PlanUP 로그인 중 오류 (HTTP $code): $($_.Exception.Message)"
}

$token = $auth.access_token
$hdr = @{
  apikey          = $SUPABASE_ANON_KEY
  Authorization   = "Bearer $token"
  'Content-Type'  = 'application/json; charset=utf-8'
}

# ── 올리기 ───────────────────────────────────────────────────────
# 지난 메일을 먼저 치운다. 당일치만 두기로 했으므로 오늘 0시 이전은 전부 지운다.
$cutoff = (Get-Date).Date.AddDays(-($Days - 1)).ToString("yyyy-MM-ddTHH:mm:sszzz")
Invoke-RestMethod -Method Delete `
  -Uri "$SUPABASE_URL/rest/v1/mail_items?sent_at=lt.$([uri]::EscapeDataString($cutoff))" `
  -Headers $hdr | Out-Null

# 같은 메일을 다시 올려도 쌓이지 않게 (user_id, entry_id)로 덮어쓴다
$upsertHdr = $hdr.Clone()
$upsertHdr['Prefer'] = 'resolution=merge-duplicates,return=minimal'

# user_id는 테이블 기본값(auth.uid())이 채워주므로 여기서 실어 보내지 않는다.
$sent = 0
$batch = 200
for ($i = 0; $i -lt $items.Count; $i += $batch) {
  $slice = @($items[$i..([math]::Min($i + $batch - 1, $items.Count - 1))])
  # PowerShell 5.1의 ConvertTo-Json은 원소가 하나면 배열로 안 싸줘서 직접 맞춰준다
  $json = $slice | ConvertTo-Json -Depth 4
  if ($slice.Count -eq 1) { $json = "[$json]" }
  try {
    Invoke-RestMethod -Method Post -Uri "$SUPABASE_URL/rest/v1/mail_items" `
      -Headers $upsertHdr -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
  } catch {
    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
    if ($code -eq 404) {
      throw "mail_items 테이블이 아직 없어요. Supabase SQL Editor에서 supabase-mail.sql을 먼저 실행해주세요."
    }
    throw "메일을 올리는 중 오류 (HTTP $code): $($_.Exception.Message)"
  }
  $sent += $slice.Count
  Write-Host ("  올림 {0}/{1}" -f $sent, $items.Count)
}

Write-Host ""
Write-Host ("완료 — PlanUP 메일 탭에서 확인하세요 ({0}건)" -f $sent) -ForegroundColor Green
