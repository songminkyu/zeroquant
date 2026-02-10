<#
.SYNOPSIS
    git commit 전 CI 전체 검증 훅
.DESCRIPTION
    CI workflow(.github/workflows/ci.yml)의 모든 job을 로컬에서 재현합니다.
    1) cargo +nightly fmt --all --check
    2) cargo clippy --all-targets --all-features -- -D warnings
    3) cargo test --workspace
    4) npm run lint   (frontend/ 변경 시)
    5) npm run build  (frontend/ 변경 시)
    종료 코드 2 = 차단, 0 = 통과
#>

$toolInput = $env:CLAUDE_TOOL_INPUT | ConvertFrom-Json -ErrorAction SilentlyContinue

if (-not $toolInput) { exit 0 }

$command = if ($toolInput.command) { $toolInput.command } else { "" }

# git commit 명령인지 확인
if ($command -notmatch "git\s+commit") { exit 0 }

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = "D:\Trader" }

Push-Location $projectDir
$env:SQLX_OFFLINE = "true"

# staged 파일 목록으로 변경 범위 파악
$stagedFiles = & git diff --cached --name-only 2>&1
$hasFrontend = $stagedFiles | Where-Object { $_ -match "^frontend/" }
$hasRust = $stagedFiles | Where-Object { $_ -match "\.(rs|toml)$" }

# ===== Rust 검증 (rust-check + rust-test job) =====
if ($hasRust) {

    # 1. cargo +nightly fmt --all --check
    Write-Host "🔍 [Hook 1/5] 포맷 검사 (nightly)..." -ForegroundColor Cyan
    & cargo +nightly fmt --all --check 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🚫 [Hook] 포맷 미적용. 'cargo +nightly fmt --all' 실행 후 다시 stage 하세요." -ForegroundColor Red
        Pop-Location
        exit 2
    }
    Write-Host "  ✅ fmt 통과" -ForegroundColor Green

    # 2. cargo clippy --all-targets --all-features -- -D warnings
    Write-Host "🔍 [Hook 2/5] Clippy 검사..." -ForegroundColor Cyan
    $clippyResult = & cargo clippy --all-targets --all-features --message-format=short -- -D warnings 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🚫 [Hook] Clippy 경고 발견:" -ForegroundColor Red
        $clippyResult | Where-Object { $_ -match "^(error|warning)" } `
                      | Where-Object { $_ -notmatch "ts-rs failed to parse|failed to parse serde" } `
                      | Select-Object -Last 15 `
                      | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Pop-Location
        exit 2
    }
    Write-Host "  ✅ clippy 통과" -ForegroundColor Green

    # 3. cargo test --workspace
    Write-Host "🔍 [Hook 3/5] 테스트 실행..." -ForegroundColor Cyan
    $testResult = & cargo test --workspace 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🚫 [Hook] 테스트 실패:" -ForegroundColor Red
        $testResult | Where-Object { $_ -match "^(test .+ FAILED|failures::|error\[)" } `
                    | Select-Object -Last 15 `
                    | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Pop-Location
        exit 2
    }
    Write-Host "  ✅ test 통과" -ForegroundColor Green

} else {
    Write-Host "⏭️ [Hook 1-3/5] Rust 변경 없음 — 스킵" -ForegroundColor DarkGray
}

# ===== Frontend 검증 (frontend job) =====
if ($hasFrontend) {

    Push-Location (Join-Path $projectDir "frontend")

    # 4. npm run lint
    Write-Host "🔍 [Hook 4/5] Frontend lint..." -ForegroundColor Cyan
    $lintResult = & npm run lint 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🚫 [Hook] ESLint 에러 발견:" -ForegroundColor Red
        $lintResult | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Pop-Location  # frontend
        Pop-Location  # project
        exit 2
    }
    Write-Host "  ✅ lint 통과" -ForegroundColor Green

    # 5. npm run build
    Write-Host "🔍 [Hook 5/5] Frontend build..." -ForegroundColor Cyan
    $buildResult = & npm run build 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🚫 [Hook] 빌드 실패:" -ForegroundColor Red
        $buildResult | Where-Object { $_ -match "error|Error" } | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Pop-Location  # frontend
        Pop-Location  # project
        exit 2
    }
    Write-Host "  ✅ build 통과" -ForegroundColor Green

    Pop-Location  # frontend

} else {
    Write-Host "⏭️ [Hook 4-5/5] Frontend 변경 없음 — 스킵" -ForegroundColor DarkGray
}

Write-Host "✅ [Hook] CI 전체 검증 통과 — 커밋 허용" -ForegroundColor Green
Pop-Location
exit 0
