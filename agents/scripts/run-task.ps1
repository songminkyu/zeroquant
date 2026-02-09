<#
.SYNOPSIS
    단일 작업 파이프라인 — Explorer → Architect → [Migrator] → Implementer → Validator

.DESCRIPTION
    지정된 작업 ID에 대해 5단계 파이프라인을 실행합니다.
    각 단계 완료 시 progress.json에 기록하여 중단 복구를 지원합니다.

.PARAMETER TaskId
    작업 ID (예: B-8, A-1)

.PARAMETER DryRun
    설계까지만 실행 (코드 생성 안 함)

.PARAMETER Force
    완료된 단계도 재실행

.EXAMPLE
    .\run-task.ps1 -TaskId B-8
    .\run-task.ps1 -TaskId B-8 -DryRun
    .\run-task.ps1 -TaskId B-8 -Force
#>

param(
    [Parameter(Mandatory)]
    [string]$TaskId,

    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# 프로젝트 루트
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path "$projectRoot\CLAUDE.md")) {
    $projectRoot = (Get-Location).Path
}

$taskFile = Join-Path $projectRoot "agents\tasks\$TaskId.json"
if (-not (Test-Path $taskFile)) {
    Write-Error "작업 파일 없음: $taskFile"
    exit 1
}

$task = Get-Content $taskFile -Raw | ConvertFrom-Json
$outDir = Join-Path $projectRoot "agents\output\$TaskId"
$progressFile = Join-Path $outDir "progress.json"
$invokeScript = Join-Path $projectRoot "agents\scripts\invoke-agent.ps1"

# 출력 디렉토리 생성
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host " [$TaskId] $($task.title)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

# --- 진행 상태 관리 ---

function Get-TaskProgress {
    if (Test-Path $progressFile) {
        return Get-Content $progressFile -Raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{
        completed_steps = @()
        status          = "pending"
        started_at      = (Get-Date -Format "o")
        last_updated    = (Get-Date -Format "o")
    }
}

function Save-TaskProgress {
    param([string]$Step, [string]$Status = "in_progress")

    $prog = Get-TaskProgress
    $steps = [System.Collections.ArrayList]@($prog.completed_steps)
    if ($Step -notin $steps) {
        $steps.Add($Step) | Out-Null
    }
    $prog.completed_steps = $steps.ToArray()
    $prog.status = $Status
    $prog.last_updated = (Get-Date -Format "o")
    $prog | ConvertTo-Json -Depth 5 | Set-Content $progressFile -Encoding UTF8
}

function Test-StepCompleted {
    param([string]$Step)
    if ($Force) { return $false }

    $prog = Get-TaskProgress
    $stepCompleted = $Step -in $prog.completed_steps

    # 출력 파일 존재 여부도 확인
    $outputExists = (Get-ChildItem -Path $outDir -Filter "$Step*" -ErrorAction SilentlyContinue).Count -gt 0

    return ($stepCompleted -and $outputExists)
}

# --- 파이프라인 실행 ---

$startTime = Get-Date

# Step 1: Explorer (탐색)
$step1File = Join-Path $outDir "01-explore.json"
if (-not (Test-StepCompleted "01-explore")) {
    Write-Host "[$TaskId] Step 1/5: 탐색 중..." -ForegroundColor Yellow

    $relevantCrates = ($task.relevant_crates -join ", ")
    $checklist = ($task.checklist -join "`n  - ")

    $explorePrompt = @"
다음 작업에 필요한 기존 코드를 탐색하세요.

## 작업: $($task.title)
$($task.description)

## 탐색 대상 crate: $relevantCrates

## 체크리스트
  - $checklist

코딩 규칙은 agents/config/rules.md를 참조하세요.
"@

    & $invokeScript -AgentType explorer -Prompt $explorePrompt `
      -OutputFile $step1File -MaxTurns 20 -TimeoutSeconds 600
    Save-TaskProgress "01-explore"
} else {
    Write-Host "[$TaskId] Step 1/5: 탐색 — 이전 결과 재사용" -ForegroundColor DarkGray
}

# Step 2: Architect (설계)
$step2File = Join-Path $outDir "02-design.md"
if (-not (Test-StepCompleted "02-design")) {
    Write-Host "[$TaskId] Step 2/5: 설계 중..." -ForegroundColor Yellow

    $exploreResult = ""
    if (Test-Path $step1File) {
        $exploreResult = Get-Content $step1File -Raw -Encoding UTF8
    }

    $checklist = ($task.checklist -join "`n  - ")

    $designPrompt = @"
다음 탐색 결과를 기반으로 구현 설계서를 작성하세요.

## 작업: $($task.title)
$($task.description)

## 체크리스트
  - $checklist

## 탐색 결과:
$exploreResult

코딩 규칙은 agents/config/rules.md를 참조하세요.
"@

    & $invokeScript -AgentType architect -Prompt $designPrompt `
      -OutputFile $step2File -Model opus -MaxTurns 15 -TimeoutSeconds 600
    Save-TaskProgress "02-design"
} else {
    Write-Host "[$TaskId] Step 2/5: 설계 — 이전 결과 재사용" -ForegroundColor DarkGray
}

# DryRun 종료
if ($DryRun) {
    Save-TaskProgress "02-design" "dry_run_complete"
    Write-Host ""
    Write-Host "[$TaskId] DryRun 완료" -ForegroundColor Cyan
    Write-Host "  설계서: $step2File"
    exit 0
}

# Step 2.5: Migrator (DB 변경이 있는 경우)
$step25File = Join-Path $outDir "02.5-migrate.json"
if ($task.has_db_changes -and -not (Test-StepCompleted "02.5-migrate")) {
    Write-Host "[$TaskId] Step 2.5/5: DB 마이그레이션..." -ForegroundColor Yellow

    $designResult = ""
    if (Test-Path $step2File) {
        $designResult = Get-Content $step2File -Raw -Encoding UTF8
    }

    $migratePrompt = @"
다음 설계서의 DB 변경사항을 SQL 마이그레이션으로 생성하고 실행하세요.

## 설계서:
$designResult

DB 접속: podman exec -it trader-timescaledb psql -U trader -d trader -c "SQL문"
psql 직접 실행 절대 금지.
"@

    & $invokeScript -AgentType migrator -Prompt $migratePrompt `
      -OutputFile $step25File -MaxTurns 15 -TimeoutSeconds 600
    Save-TaskProgress "02.5-migrate"
} elseif (-not $task.has_db_changes) {
    Write-Host "[$TaskId] Step 2.5/5: DB 변경 없음 — 건너뜀" -ForegroundColor DarkGray
} else {
    Write-Host "[$TaskId] Step 2.5/5: 마이그레이션 — 이전 결과 재사용" -ForegroundColor DarkGray
}

# Step 3: Implementer (구현)
$step3File = Join-Path $outDir "03-implement.json"
if (-not (Test-StepCompleted "03-implement")) {
    Write-Host "[$TaskId] Step 3/5: 구현 중..." -ForegroundColor Yellow

    $designResult = ""
    if (Test-Path $step2File) {
        $designResult = Get-Content $step2File -Raw -Encoding UTF8
    }

    $implPrompt = @"
다음 설계서를 기반으로 코드를 구현하세요.

## 설계서:
$designResult

## 코딩 규칙: agents/config/rules.md 참조
## 중요: rust_decimal::Decimal 사용, unwrap() 금지, 한글 주석
"@

    & $invokeScript -AgentType implementer -Prompt $implPrompt `
      -OutputFile $step3File -Model opus -MaxTurns 50 -TimeoutSeconds 900
    Save-TaskProgress "03-implement"
} else {
    Write-Host "[$TaskId] Step 3/5: 구현 — 이전 결과 재사용" -ForegroundColor DarkGray
}

# Step 4: Validator (검증)
$step4File = Join-Path $outDir "04-validate.json"
$relevantCrates = ($task.relevant_crates -join ", ")
$validatePrompt = "다음 crate를 빌드하고 clippy, 테스트를 실행하세요: $relevantCrates"

if (-not (Test-StepCompleted "04-validate")) {
    Write-Host "[$TaskId] Step 4/5: 검증 중..." -ForegroundColor Yellow

    & $invokeScript -AgentType validator -Prompt $validatePrompt `
      -OutputFile $step4File -MaxTurns 10 -TimeoutSeconds 600
    Save-TaskProgress "04-validate"
} else {
    Write-Host "[$TaskId] Step 4/5: 검증 — 이전 결과 재사용" -ForegroundColor DarkGray
}

# Step 5: 실패 시 재시도 (최대 2회)
$latestValidation = Get-ChildItem -Path $outDir -Filter "04-validate*.json" -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -Last 1

$validationSuccess = $false
if ($latestValidation) {
    $validationContent = Get-Content $latestValidation.FullName -Raw -Encoding UTF8
    # JSON 파싱 시도 — 성공 여부 확인
    try {
        $validationObj = $validationContent | ConvertFrom-Json
        $validationSuccess = $validationObj.success -eq $true
    } catch {
        # JSON 파싱 실패 — 텍스트에서 성공 여부 추론
        $validationSuccess = $validationContent -match '"success"\s*:\s*true' -or
                             $validationContent -match 'cargo build.*성공' -or
                             $validationContent -match 'Compiling.*Finished'
    }
}

$retry = 0
while (-not $validationSuccess -and $retry -lt 2) {
    $retry++
    Write-Host "[$TaskId] 재시도 $retry/2..." -ForegroundColor Magenta

    # 에러 내용 추출
    $errorContent = ""
    if ($latestValidation) {
        $errorContent = Get-Content $latestValidation.FullName -Raw -Encoding UTF8
    }

    $fixPrompt = @"
빌드/테스트 에러를 수정하세요.

## 에러 내용:
$errorContent

## 코딩 규칙: agents/config/rules.md 참조
"@

    $fixFile = Join-Path $outDir "03-fix-$retry.json"
    & $invokeScript -AgentType implementer -Prompt $fixPrompt `
      -OutputFile $fixFile -Model opus -MaxTurns 30 -TimeoutSeconds 600

    $retryValidateFile = Join-Path $outDir "04-validate-retry$retry.json"
    & $invokeScript -AgentType validator -Prompt $validatePrompt `
      -OutputFile $retryValidateFile -MaxTurns 10 -TimeoutSeconds 600

    $latestValidation = Get-Item $retryValidateFile
    try {
        $validationObj = Get-Content $retryValidateFile -Raw | ConvertFrom-Json
        $validationSuccess = $validationObj.success -eq $true
    } catch {
        $retryContent = Get-Content $retryValidateFile -Raw
        $validationSuccess = $retryContent -match '"success"\s*:\s*true'
    }
}

# 최종 상태 저장
$finalStatus = if ($validationSuccess) { "success" } else { "failed" }
Save-TaskProgress "05-complete" $finalStatus

$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host " [$TaskId] 결과: $($finalStatus.ToUpper())" -ForegroundColor $(if ($validationSuccess) { "Green" } else { "Red" })
Write-Host " 소요 시간: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
