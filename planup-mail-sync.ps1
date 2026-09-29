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

    # PlanUP에 올리기 (닉네임/비밀번호는 PlanUP 로그인과 동일)
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -Nickname sewoning

  매일 자동으로 돌리려면 작업 스케줄러에 등록 (아래 -InstallTask 참고)
    powershell -ExecutionPolicy Bypass -File planup-mail-sync.ps1 -InstallTask -Nickname sewoning
#>
param(
  [string]$Nickname,
  [string]$Password,
  [int]$Days = 1,          # 1 = 당일만
  [switch]$Preview,        # 올리지 않고 결과만 보기
  [switch]$InstallTask,    # 작업 스케줄러에 등록만 하고 종료
  [string]$AtTime = "08:30"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SUPABASE_URL = 'https://awtdpyoiecymhnwjvtki.supabase.co'
$SUPABASE_ANON_KEY = 'sb_publishable_GgvVhU2ecDXearjojyz-6Q_Yxlnp-TB'

# 본문에서 가져올 길이. 예산·단가 같은 민감한 내용은 보통 이 뒤쪽에 있어서,
# 여기서 끊으면 검색에 쓸 단서는 남기면서 내용은 거의 가져오지 않는다.
$PreviewLen = 200

# ── 작업 스케줄러 등록 ────────────────────────────────────────────
if ($InstallTask) {
  if (-not $Nickname) { throw "-Nickname 이 필요해요" }
  $self = $MyInvocation.MyCommand.Path
  $action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Nickname $Nickname"
  $trigger = New-ScheduledTaskTrigger -Daily -At $AtTime
  Register-ScheduledTask -TaskName "PlanUP 메일 동기화" -Action $action -Trigger $trigger `
    -Description "당일 아웃룩 메일 헤더를 PlanUP으로 올립니다" -Force | Out-Null
  Write-Host "작업 스케줄러에 등록했어요 — 매일 $AtTime 실행" -ForegroundColor Green
  Write-Host "비밀번호는 저장되지 않으므로, 처음 한 번은 직접 실행해서 입력해야 해요." -ForegroundColor Yellow
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
  $sec = Read-Host "PlanUP 비밀번호 ($Nickname)" -AsSecureString
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
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
