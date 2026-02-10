<#
.SYNOPSIS
    위험한 Bash 명령 사전 검증 + rust-analyzer 좀비 자동 정리 훅
.DESCRIPTION
    1) 프로덕션 DB 직접 접근, 민감 정보 노출 등을 차단합니다.
    2) 10분 쿨다운으로 rust-analyzer 좀비 프로세스를 자동 정리합니다.
    종료 코드 2 = 차단, 0 = 통과
#>

# ========== 좀비 rust-analyzer 자동 정리 (10분 쿨다운) ==========
$stampFile = Join-Path $env:TEMP "ra-cleanup-stamp.txt"
$cooldownMin = 10
$shouldClean = $true

if (Test-Path $stampFile) {
    $lastRun = [datetime]::Parse((Get-Content $stampFile -Raw).Trim())
    if (((Get-Date) - $lastRun).TotalMinutes -lt $cooldownMin) {
        $shouldClean = $false
    }
}

if ($shouldClean) {
    $raProcs = Get-Process rust-analyzer -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending
    if ($raProcs -and $raProcs.Count -gt 2) {
        $stale = $raProcs | Select-Object -Skip 2
        $freedMB = 0
        foreach ($p in $stale) {
            $freedMB += [math]::Round($p.WorkingSet64 / 1MB)
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        if ($freedMB -gt 100) {
            Write-Host "[Hook] rust-analyzer $($stale.Count)개 정리 (~${freedMB}MB 해제)" -ForegroundColor DarkGray
        }
    }
    # proc-macro-srv도 정리 (2개 초과 시)
    $pmProcs = Get-Process rust-analyzer-proc-macro-srv -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending
    if ($pmProcs -and $pmProcs.Count -gt 2) {
        $pmProcs | Select-Object -Skip 2 | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Set-Content $stampFile (Get-Date).ToString("o")
}
# ================================================================

$toolInput = $env:CLAUDE_TOOL_INPUT | ConvertFrom-Json -ErrorAction SilentlyContinue

if (-not $toolInput) { exit 0 }

$command = if ($toolInput.command) { $toolInput.command } else { "" }

if (-not $command) { exit 0 }

# 1. powershell 중첩 명령 우회 차단
if ($command -match "powershell(.exe)?\s+(-c|-Command)\s") {
    Write-Host ""
    Write-Host "[Hook] powershell -c 중첩 명령은 차단되었습니다." -ForegroundColor Red
    Write-Host "   → 명령을 직접 실행하세요." -ForegroundColor Cyan
    Write-Host ""
    exit 2
}

# 2. 호스트 직접 DB/Redis 접속 차단 (podman exec 필수)
if ($command -match "^\s*(psql|redis-cli|pg_dump|pg_restore)\s") {
    Write-Host ""
    Write-Host "🚫 [Hook] 호스트에서 직접 DB/Redis 접속이 차단되었습니다." -ForegroundColor Red
    Write-Host "   → podman exec -it trader-timescaledb psql -U trader -d trader" -ForegroundColor Cyan
    Write-Host "   → podman exec -it trader-redis redis-cli" -ForegroundColor Cyan
    Write-Host ""
    exit 2
}

# 2. API 키/시크릿 평문 노출 차단
if ($command -match "(api_key|api_secret|access_token|API_KEY|API_SECRET|ACCESS_TOKEN)\s*=\s*['""]?[A-Za-z0-9+/=]{20,}") {
    Write-Host ""
    Write-Host "🚫 [Hook] 민감 정보(API 키/시크릿)가 명령에 포함되어 차단되었습니다." -ForegroundColor Red
    Write-Host "   → 환경변수 또는 웹 UI Settings에서 설정하세요." -ForegroundColor Cyan
    Write-Host ""
    exit 2
}

# 3. 프로덕션 DB 직접 DROP/TRUNCATE 차단
if ($command -match "(?i)(DROP\s+TABLE|DROP\s+DATABASE|TRUNCATE\s+TABLE)") {
    Write-Host ""
    Write-Host "🚫 [Hook] 파괴적 SQL 명령이 차단되었습니다: $($Matches[0])" -ForegroundColor Red
    Write-Host "   → 마이그레이션 파일로 스키마 변경하세요." -ForegroundColor Cyan
    Write-Host ""
    exit 2
}

exit 0
