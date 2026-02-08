# ZeroQuant 릴리스 빌드 스크립트
# 프론트엔드 + 백엔드 통합 빌드 후 release/ 폴더에 아티팩트 생성
#
# 사용법:
#   .\scripts\build-release.ps1
#   .\scripts\build-release.ps1 -SkipFrontend   # 프론트엔드 빌드 스킵
#   .\scripts\build-release.ps1 -SkipBackend    # 백엔드 빌드 스킵

param(
    [switch]$SkipFrontend,
    [switch]$SkipBackend
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# 빌드 대상 패키지 → 실행 파일 매핑
$Binaries = @(
    @{ Package = "trader-api";       Exe = "trader-api.exe" }
    @{ Package = "trader-cli";       Exe = "trader.exe" }
    @{ Package = "trader-collector"; Exe = "trader-collector.exe" }
)

Write-Host "=== ZeroQuant Release Build ===" -ForegroundColor Cyan
Write-Host "Root: $RootDir"

# 1단계: 프론트엔드 빌드
if (-not $SkipFrontend) {
    Write-Host "`n[1/3] 프론트엔드 빌드..." -ForegroundColor Yellow
    Push-Location "$RootDir\frontend"
    try {
        npm ci
        if ($LASTEXITCODE -ne 0) { throw "npm ci 실패" }
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build 실패" }
        Write-Host "프론트엔드 빌드 완료" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
} else {
    Write-Host "`n[1/3] 프론트엔드 빌드 스킵" -ForegroundColor DarkGray
}

# 2단계: Rust 릴리스 빌드 (3개 패키지)
if (-not $SkipBackend) {
    Write-Host "`n[2/3] Rust 릴리스 빌드..." -ForegroundColor Yellow
    $packages = ($Binaries | ForEach-Object { "-p $($_.Package)" }) -join " "
    Push-Location $RootDir
    try {
        $cmd = "cargo build --release -p trader-api -p trader-cli -p trader-collector"
        Write-Host "  $cmd"
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) { throw "cargo build 실패" }
        Write-Host "Rust 빌드 완료" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
} else {
    Write-Host "`n[2/3] Rust 빌드 스킵" -ForegroundColor DarkGray
}

# 3단계: 아티팩트 조합
Write-Host "`n[3/3] 릴리스 아티팩트 생성..." -ForegroundColor Yellow

$ReleaseDir = "$RootDir\release"
if (Test-Path $ReleaseDir) {
    Remove-Item -Recurse -Force $ReleaseDir
}
New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null

# 실행 파일 복사
foreach ($bin in $Binaries) {
    $src = "$RootDir\target\release\$($bin.Exe)"
    if (Test-Path $src) {
        Copy-Item $src "$ReleaseDir\$($bin.Exe)"
        Write-Host "  $($bin.Exe) 복사 완료" -ForegroundColor Green
    } else {
        Write-Host "  경고: $($bin.Exe) 없음 (빌드 스킵?)" -ForegroundColor Red
    }
}

# sqlx-cli 복사 (마이그레이션 적용에 필요)
$SqlxPath = (Get-Command sqlx -ErrorAction SilentlyContinue)?.Source
if ($SqlxPath) {
    Copy-Item $SqlxPath "$ReleaseDir\sqlx.exe"
    Write-Host "  sqlx.exe 복사 완료" -ForegroundColor Green
} else {
    Write-Host "  경고: sqlx-cli 미설치 - cargo install sqlx-cli --no-default-features --features postgres" -ForegroundColor Red
}

# 프론트엔드 dist 복사
$DistDir = "$RootDir\frontend\dist"
if (Test-Path $DistDir) {
    Copy-Item -Recurse $DistDir "$ReleaseDir\dist"
    Write-Host "  frontend/dist 복사 완료" -ForegroundColor Green
} else {
    Write-Host "  경고: $DistDir 없음 (프론트엔드 빌드 스킵?)" -ForegroundColor Red
}

# config 복사
$ConfigDir = "$RootDir\config"
if (Test-Path $ConfigDir) {
    Copy-Item -Recurse $ConfigDir "$ReleaseDir\config"
    Write-Host "  config/ 복사 완료" -ForegroundColor Green
}

# .env 복사
$EnvFile = "$RootDir\.env"
if (Test-Path $EnvFile) {
    Copy-Item $EnvFile "$ReleaseDir\.env"
    Write-Host "  .env 복사 완료" -ForegroundColor Green
} else {
    Write-Host "  경고: .env 없음 - 배포 환경에서 직접 생성 필요" -ForegroundColor Red
}

Write-Host "`n=== 빌드 완료 ===" -ForegroundColor Cyan
Write-Host "릴리스 디렉토리: $ReleaseDir"
Write-Host ""
Write-Host "포함 파일:" -ForegroundColor White
Get-ChildItem $ReleaseDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($ReleaseDir.Length + 1)
    $size = "{0:N1} MB" -f ($_.Length / 1MB)
    Write-Host "  $rel ($size)"
}
