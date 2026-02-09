<#
.SYNOPSIS
    Phase 실행 — 여러 그룹을 병렬로 실행

.DESCRIPTION
    Phase 번호에 따라 해당 그룹들을 병렬 Job으로 실행합니다.
    Phase 1: A + B + G (동시)
    Phase 2: C + D (동시)
    Phase 3: E + F (동시)

.PARAMETER Phase
    Phase 번호 (1, 2, 3)

.PARAMETER StopOnFailure
    그룹 내 실패 시 해당 그룹 중단

.PARAMETER DryRun
    설계까지만 실행

.EXAMPLE
    .\run-phase.ps1 -Phase 1
    .\run-phase.ps1 -Phase 2 -StopOnFailure
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet(1, 2, 3)]
    [int]$Phase,

    [switch]$StopOnFailure,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# 프로젝트 루트
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path "$projectRoot\CLAUDE.md")) {
    $projectRoot = (Get-Location).Path
}

# Phase별 그룹 매핑
$phaseGroups = @{
    1 = @("A", "B", "G")
    2 = @("C", "D")
    3 = @("E", "F")
}

$groups = $phaseGroups[$Phase]
$runGroupScript = Join-Path $projectRoot "agents\scripts\run-group.ps1"

Write-Host ""
Write-Host "################################################" -ForegroundColor Magenta
Write-Host " Phase $Phase 시작 — 그룹: $($groups -join ', ')" -ForegroundColor Magenta
Write-Host " 모드: $(if ($DryRun) { 'DryRun (설계만)' } else { '전체 실행' })" -ForegroundColor Magenta
Write-Host "################################################" -ForegroundColor Magenta
Write-Host ""

$phaseStart = Get-Date

# 각 그룹을 병렬 Job으로 실행
$jobs = @()
foreach ($group in $groups) {
    $jobs += Start-Job -Name "Group-$group" -ScriptBlock {
        param($script, $grp, $stopFlag, $dryFlag, $projRoot)

        Set-Location $projRoot

        $params = @{ Group = $grp }
        if ($stopFlag) { $params.StopOnFailure = $true }
        if ($dryFlag) { $params.DryRun = $true }

        & $script @params
    } -ArgumentList $runGroupScript, $group, $StopOnFailure.IsPresent, $DryRun.IsPresent, $projectRoot
}

Write-Host "병렬 Job 시작: $($jobs.Count)개" -ForegroundColor Cyan
Write-Host ""

# 전체 완료 대기 (Phase당 최대 4시간)
$maxWait = 14400  # 초
$allCompleted = $jobs | Wait-Job -Timeout $maxWait

# 타임아웃 체크
$timedOut = $jobs | Where-Object { $_.State -eq "Running" }
if ($timedOut) {
    Write-Host "타임아웃된 그룹: $($timedOut.Name -join ', ')" -ForegroundColor Red
    $timedOut | Stop-Job -Force
}

# 결과 수집
Write-Host ""
Write-Host "################################################" -ForegroundColor Magenta
Write-Host " Phase $Phase 결과" -ForegroundColor Magenta
Write-Host "################################################" -ForegroundColor Magenta

foreach ($job in $jobs) {
    Write-Host ""
    Write-Host "--- $($job.Name) ---" -ForegroundColor White

    if ($job.State -eq "Completed") {
        $output = Receive-Job $job
        if ($output) {
            $output | ForEach-Object { Write-Host $_ }
        }
    } elseif ($job.State -eq "Failed") {
        Write-Host "  실패: $($job.ChildJobs[0].JobStateInfo.Reason)" -ForegroundColor Red
    } else {
        Write-Host "  상태: $($job.State)" -ForegroundColor Yellow
    }
}

# Job 정리
$jobs | Remove-Job -Force -ErrorAction SilentlyContinue

$phaseElapsed = (Get-Date) - $phaseStart
Write-Host ""
Write-Host "Phase $Phase 완료 — 소요 시간: $($phaseElapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Magenta
Write-Host ""

# Phase 결과 파일 저장
$phaseResultFile = Join-Path $projectRoot "agents\output\phase-$Phase-result.json"
@{
    phase     = $Phase
    groups    = $groups
    elapsed   = $phaseElapsed.ToString('hh\:mm\:ss')
    timestamp = (Get-Date -Format "o")
} | ConvertTo-Json -Depth 5 | Set-Content $phaseResultFile -Encoding UTF8
