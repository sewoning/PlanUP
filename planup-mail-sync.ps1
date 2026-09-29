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

# 본문에서 가져올 길이. 예산·단가 같은 민감한 내용은 보통 이 뒤쪽에 있어서,
# 여기서 끊으면 검색에 쓸 단서는 남기면서 내용은 거의 가져오지 않는다.
$PreviewLen = 200

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
  try { Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false; Write-Host "자동 실행을 해제했어요." -ForegroundColor Green }
  catch { Write-Host "등록된 자동 실행이 없어요." }
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
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$self`""

  # 로그온하면 시작해서 N분마다 반복. 기간을 아주 길게 줘서 사실상 무기한으로 둔다.
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition

  # 아웃룩 COM은 로그인한 세션에서만 열리므로 대화형 사용자로 돌린다.
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
  $settings = New-ScheduledTaskSettings -StartWhenAvailable -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

  Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description '당일 아웃룩 메일 헤더를 PlanUP으로 올립니다' -Force | Out-Null

  Write-Host ""
  Write-Host "등록 완료 — $EveryMinutes 분마다 자동으로 올라가요." -ForegroundColor Green
  Write-Host "비밀번호는 이 PC의 이 계정에서만 풀리게 암호화해서 보관했어요:" -ForegroundColor Gray
  Write-Host "  $CredFile" -ForegroundColor Gray
  Write-Host "지금 바로 한 번 돌려볼게요..." -ForegroundColor Cyan
  Start-ScheduledTask -TaskName $TASK_NAME
  return
}

# ── 아웃룩에서 읽기 ───────────────────────────────────────────────
function Clean([string]$s) {
  if (-not $s) { return "" }
  ($s -replace '\s+', ' ').Trim()
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

          $body = Clean $m.Body
          if ($body.Length -gt $PreviewLen) { $body = $body.Substring(0, $PreviewLen) }

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
            preview     = $body
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
$auth = Invoke-RestMethod -Method Post `
  -Uri "$SUPABASE_URL/auth/v1/token?grant_type=password" `
  -Headers @{ apikey = $SUPABASE_ANON_KEY; 'Content-Type' = 'application/json' } `
  -Body (@{ email = $email; password = $Password } | ConvertTo-Json)

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
  Invoke-RestMethod -Method Post -Uri "$SUPABASE_URL/rest/v1/mail_items" `
    -Headers $upsertHdr -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
  $sent += $slice.Count
  Write-Host ("  올림 {0}/{1}" -f $sent, $items.Count)
}

Write-Host ""
Write-Host ("완료 — PlanUP 메일 탭에서 확인하세요 ({0}건)" -f $sent) -ForegroundColor Green
