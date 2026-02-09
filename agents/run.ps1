<#
.SYNOPSIS
    ZeroQuant 멀티에이전트 시스템 — 메인 CLI

.DESCRIPTION
    Claude CLI 기반 멀티에이전트 시스템의 진입점입니다.
    TODO_v2의 34개 작업을 자동 구현하기 위한 파이프라인을 제어합니다.

.PARAMETER Command
    실행할 명령:
    - run:      작업/그룹/Phase 실행
    - plan:     설계만 실행 (DryRun)
    - validate: workspace 전체 빌드 검증
    - status:   전체 작업 진행 상태 표시

.PARAMETER Task
    단일 작업 ID (예: B-8)

.PARAMETER Group
    그룹 ID (예: B)

.PARAMETER Phase
    Phase 번호 (1, 2, 3)

.PARAMETER DryRun
    설계까지만 실행

.PARAMETER Force
    완료된 단계도 재실행

.PARAMETER StopOnFailure
    그룹/Phase 내 실패 시 중단

.EXAMPLE
    .\agents\run.ps1 -Command run -Task B-8          # 단일 작업 실행
    .\agents\run.ps1 -Command plan -Task C-1          # 설계만 (DryRun)
    .\agents\run.ps1 -Command run -Group B            # B 그룹 전체
    .\agents\run.ps1 -Command run -Phase 1            # Phase 1 (A+B+G 병렬)
    .\agents\run.ps1 -Command validate                # workspace 빌드 검증
    .\agents\run.ps1 -Command status                  # 전체 진행 상황
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("run", "plan", "validate", "status")]
    [string]$Command,

    [string]$Task,
    [string]$Group,
    [int]$Phase,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$StopOnFailure
)

$ErrorActionPreference = "Stop"

# 프로젝트 루트 계산
$projectRoot = if (Test-Path "$PSScriptRoot\CLAUDE.md") {
    $PSScriptRoot
} elseif (Test-Path "$(Split-Path $PSScriptRoot -Parent)\CLAUDE.md") {
    Split-Path $PSScriptRoot -Parent
} else {
    (Get-Location).Path
}

$scriptsDir = Join-Path $projectRoot "agents\scripts"
$tasksDir = Join-Path $projectRoot "agents\tasks"
$outputDir = Join-Path $projectRoot "agents\output"

# CLI 배너
Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  ZeroQuant Multi-Agent System v1.0   ║" -ForegroundColor Cyan
Write-Host "  ║  Claude CLI 기반 자동 구현 시스템      ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

switch ($Command) {
    "run" {
        if ($Task) {
            $params = @{ TaskId = $Task }
            if ($DryRun) { $params.DryRun = $true }
            if ($Force) { $params.Force = $true }
            & "$scriptsDir\run-task.ps1" @params
        }
        elseif ($Group) {
            $params = @{ Group = $Group }
            if ($StopOnFailure) { $params.StopOnFailure = $true }
            if ($DryRun) { $params.DryRun = $true }
            if ($Force) { $params.Force = $true }
            & "$scriptsDir\run-group.ps1" @params
        }
        elseif ($Phase -gt 0) {
            $params = @{ Phase = $Phase }
            if ($StopOnFailure) { $params.StopOnFailure = $true }
            if ($DryRun) { $params.DryRun = $true }
            & "$scriptsDir\run-phase.ps1" @params
        }
        else {
            Write-Host "  -Task, -Group, 또는 -Phase 중 하나를 지정하세요." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  예시:" -ForegroundColor White
            Write-Host "    .\agents\run.ps1 -Command run -Task B-8" -ForegroundColor Gray
            Write-Host "    .\agents\run.ps1 -Command run -Group B" -ForegroundColor Gray
            Write-Host "    .\agents\run.ps1 -Command run -Phase 1" -ForegroundColor Gray
        }
    }

    "plan" {
        if (-not $Task) {
            Write-Host "  -Task를 지정하세요. (예: -Task B-8)" -ForegroundColor Yellow
            exit 1
        }
        & "$scriptsDir\run-task.ps1" -TaskId $Task -DryRun
    }

    "validate" {
        Write-Host "  Workspace 전체 빌드 검증..." -ForegroundColor Yellow
        $validateOutput = Join-Path $outputDir "workspace-validate.json"
        & "$scriptsDir\invoke-agent.ps1" -AgentType validator `
          -Prompt "workspace 전체를 빌드하고 clippy, 테스트를 실행하세요. cargo build, cargo clippy -- -D warnings, cargo test" `
          -OutputFile $validateOutput -MaxTurns 10 -TimeoutSeconds 900
        Write-Host "  결과: $validateOutput" -ForegroundColor Green
    }

    "status" {
        Write-Host "  ┌─────────────────────────────────────┐" -ForegroundColor White
        Write-Host "  │         전체 작업 진행 상태            │" -ForegroundColor White
        Write-Host "  └─────────────────────────────────────┘" -ForegroundColor White
        Write-Host ""

        $taskFiles = Get-ChildItem -Path $tasksDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object Name
        if (-not $taskFiles) {
            Write-Host "  작업 정의 파일 없음: $tasksDir" -ForegroundColor Yellow
            exit 0
        }

        $currentGroup = ""
        $totalSuccess = 0
        $totalFailed = 0
        $totalPending = 0

        foreach ($tf in $taskFiles) {
            $taskId = $tf.BaseName
            $taskGroup = $taskId.Split("-")[0]

            # 그룹 헤더
            if ($taskGroup -ne $currentGroup) {
                $currentGroup = $taskGroup
                Write-Host ""
                Write-Host "  [$currentGroup] 그룹" -ForegroundColor Cyan
                Write-Host "  $('-' * 40)" -ForegroundColor DarkGray
            }

            $pf = Join-Path $outputDir "$taskId\progress.json"
            if (Test-Path $pf) {
                $prog = Get-Content $pf -Raw | ConvertFrom-Json
                $steps = ($prog.completed_steps -join " → ")
                $color = switch ($prog.status) {
                    "success"           { "Green" }
                    "failed"            { "Red" }
                    "in_progress"       { "Yellow" }
                    "dry_run_complete"  { "Cyan" }
                    default             { "White" }
                }
                $icon = switch ($prog.status) {
                    "success"           { "[OK]" }
                    "failed"            { "[NG]" }
                    "in_progress"       { "[..]" }
                    "dry_run_complete"  { "[DR]" }
                    default             { "[??]" }
                }

                Write-Host "    $icon $taskId : $($prog.status)" -ForegroundColor $color -NoNewline
                Write-Host " [$steps]" -ForegroundColor DarkGray

                switch ($prog.status) {
                    "success" { $totalSuccess++ }
                    "failed"  { $totalFailed++ }
                    default   { $totalPending++ }
                }
            } else {
                Write-Host "    [  ] $taskId : pending" -ForegroundColor DarkGray
                $totalPending++
            }
        }

        $total = $totalSuccess + $totalFailed + $totalPending
        Write-Host ""
        Write-Host "  $('=' * 40)" -ForegroundColor White
        Write-Host "  총 $total개 | 성공: $totalSuccess | 실패: $totalFailed | 대기: $totalPending" -ForegroundColor White

        if ($total -gt 0) {
            $pct = [math]::Round(($totalSuccess / $total) * 100, 1)
            Write-Host "  진행률: $pct%" -ForegroundColor $(if ($pct -eq 100) { "Green" } elseif ($pct -gt 50) { "Yellow" } else { "White" })
        }
        Write-Host ""
    }
}
