<#
.SYNOPSIS
    그룹 실행 — 지정된 그룹의 모든 작업을 순차 실행

.DESCRIPTION
    그룹 ID(A~G)에 해당하는 모든 작업을 순서대로 실행합니다.
    이미 완료된 작업은 건너뜁니다.

.PARAMETER Group
    그룹 ID (A, B, C, D, E, F, G)

.PARAMETER StopOnFailure
    실패 시 다음 작업 중단

.PARAMETER DryRun
    설계까지만 실행

.PARAMETER Force
    완료된 단계도 재실행

.EXAMPLE
    .\run-group.ps1 -Group B
    .\run-group.ps1 -Group B -StopOnFailure
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("A", "B", "C", "D", "E", "F", "G")]
    [string]$Group,

    [switch]$StopOnFailure,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# 프로젝트 루트
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path "$projectRoot\CLAUDE.md")) {
    $projectRoot = (Get-Location).Path
}

$tasksDir = Join-Path $projectRoot "agents\tasks"
$runTaskScript = Join-Path $projectRoot "agents\scripts\run-task.ps1"

# 그룹에 해당하는 작업 파일 찾기
$taskFiles = Get-ChildItem -Path $tasksDir -Filter "$Group-*.json" | Sort-Object Name
if ($taskFiles.Count -eq 0) {
    Write-Error "그룹 $Group에 해당하는 작업 없음"
    exit 1
}

$tasks = $taskFiles | ForEach-Object { $_.BaseName }

Write-Host ""
Write-Host "########################################" -ForegroundColor Cyan
Write-Host " 그룹 [$Group] 실행 — $($tasks.Count)개 작업" -ForegroundColor Cyan
Write-Host " 작업: $($tasks -join ', ')" -ForegroundColor Cyan
Write-Host "########################################" -ForegroundColor Cyan
Write-Host ""

$results = @()
$groupStart = Get-Date

foreach ($taskId in $tasks) {
    # 이미 완료된 작업 건너뜀
    $progressFile = Join-Path $projectRoot "agents\output\$taskId\progress.json"
    if (-not $Force -and (Test-Path $progressFile)) {
        $prog = Get-Content $progressFile -Raw | ConvertFrom-Json
        if ($prog.status -eq "success") {
            Write-Host "[$taskId] 이미 완료됨 — 건너뜀" -ForegroundColor DarkGray
            $results += [PSCustomObject]@{ task = $taskId; status = "skipped_completed" }
            continue
        }
    }

    # 작업 실행
    $taskParams = @{ TaskId = $taskId }
    if ($DryRun) { $taskParams.DryRun = $true }
    if ($Force) { $taskParams.Force = $true }

    & $runTaskScript @taskParams

    # 결과 확인
    $progressFile = Join-Path $projectRoot "agents\output\$taskId\progress.json"
    if (Test-Path $progressFile) {
        $prog = Get-Content $progressFile -Raw | ConvertFrom-Json
        $results += [PSCustomObject]@{ task = $taskId; status = $prog.status }

        if ($StopOnFailure -and $prog.status -eq "failed") {
            Write-Host ""
            Write-Host "[$Group] $taskId 실패 — 그룹 실행 중단" -ForegroundColor Red
            break
        }
    } else {
        $results += [PSCustomObject]@{ task = $taskId; status = "unknown" }
    }
}

# 그룹 결과 요약
$groupElapsed = (Get-Date) - $groupStart

Write-Host ""
Write-Host "########################################" -ForegroundColor Cyan
Write-Host " 그룹 [$Group] 결과 요약" -ForegroundColor Cyan
Write-Host "########################################" -ForegroundColor Cyan

$successCount = ($results | Where-Object { $_.status -eq "success" -or $_.status -eq "skipped_completed" }).Count
$failedCount = ($results | Where-Object { $_.status -eq "failed" }).Count
$pendingCount = ($results | Where-Object { $_.status -notin @("success", "skipped_completed", "failed") }).Count

foreach ($r in $results) {
    $color = switch ($r.status) {
        "success"           { "Green" }
        "skipped_completed" { "DarkGray" }
        "failed"            { "Red" }
        "dry_run_complete"  { "Cyan" }
        default             { "Yellow" }
    }
    Write-Host "  $($r.task): $($r.status)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  성공: $successCount | 실패: $failedCount | 진행중: $pendingCount" -ForegroundColor White
Write-Host "  소요 시간: $($groupElapsed.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host ""

# 그룹 결과 파일 저장
$groupResultFile = Join-Path $projectRoot "agents\output\group-$Group-result.json"
@{
    group     = $Group
    tasks     = $results
    success   = $successCount
    failed    = $failedCount
    pending   = $pendingCount
    elapsed   = $groupElapsed.ToString('hh\:mm\:ss')
    timestamp = (Get-Date -Format "o")
} | ConvertTo-Json -Depth 5 | Set-Content $groupResultFile -Encoding UTF8
