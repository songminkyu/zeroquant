<#
.SYNOPSIS
    Claude CLI 래퍼 — 에이전트 타입별 claude -p 호출

.DESCRIPTION
    지정된 에이전트 타입에 따라 적절한 도구 권한과 모델로 claude CLI를 호출합니다.
    Start-Job으로 별도 프로세스에서 실행하여 타임아웃 제어가 가능합니다.

.PARAMETER AgentType
    에이전트 종류: explorer, architect, implementer, validator, migrator

.PARAMETER Prompt
    에이전트에 전달할 프롬프트 텍스트

.PARAMETER OutputFile
    결과를 저장할 파일 경로

.PARAMETER Model
    사용할 모델 (기본: sonnet)

.PARAMETER MaxTurns
    최대 에이전트 턴 수 (기본: 20)

.PARAMETER TimeoutSeconds
    타임아웃 초 (기본: 600)

.EXAMPLE
    .\invoke-agent.ps1 -AgentType explorer -Prompt "trader-core 탐색" -OutputFile "output/test.json"
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("explorer", "architect", "implementer", "validator", "migrator")]
    [string]$AgentType,

    [Parameter(Mandatory)]
    [string]$Prompt,

    [Parameter(Mandatory)]
    [string]$OutputFile,

    [string]$Model,
    [int]$MaxTurns,
    [int]$TimeoutSeconds = 600
)

# 프로젝트 루트 기준 경로 계산
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path "$projectRoot\CLAUDE.md")) {
    $projectRoot = (Get-Location).Path
}

$promptFile = Join-Path $projectRoot "agents\config\prompts\$AgentType.md"
if (-not (Test-Path $promptFile)) {
    Write-Error "프롬프트 파일 없음: $promptFile"
    exit 1
}

# 에이전트별 도구 권한 매핑
$toolsMap = @{
    explorer    = 'Read,Glob,Grep,mcp__serena__find_symbol,mcp__serena__get_symbols_overview,mcp__serena__search_for_pattern,mcp__serena__find_referencing_symbols'
    architect   = 'Read,Glob,Grep'
    implementer = 'Read,Write,Edit,Glob,Grep,"Bash(cargo *)","Bash(rustfmt *)"'
    validator   = '"Bash(cargo *)",Read,Glob,Grep'
    migrator    = 'Write,Read,"Bash(podman exec *)"'
}

# 에이전트별 기본 모델
$defaultModels = @{
    explorer    = "sonnet"
    architect   = "opus"
    implementer = "opus"
    validator   = "sonnet"
    migrator    = "sonnet"
}

# 에이전트별 기본 MaxTurns
$defaultTurns = @{
    explorer    = 20
    architect   = 15
    implementer = 50
    validator   = 10
    migrator    = 15
}

# 파라미터 기본값 적용
if (-not $Model) { $Model = $defaultModels[$AgentType] }
if ($MaxTurns -eq 0) { $MaxTurns = $defaultTurns[$AgentType] }

$tools = $toolsMap[$AgentType]

# 출력 디렉토리 생성
$outputDir = Split-Path $OutputFile -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

Write-Host "  [$AgentType] 모델=$Model, 턴=$MaxTurns, 타임아웃=${TimeoutSeconds}s" -ForegroundColor Cyan

# 프롬프트를 임시 파일에 저장 (긴 프롬프트 처리)
$tempPromptFile = [System.IO.Path]::GetTempFileName()
$Prompt | Set-Content -Path $tempPromptFile -Encoding UTF8

# Claude CLI를 별도 Job으로 실행
$job = Start-Job -ScriptBlock {
    param($tempFile, $promptFilePath, $toolsStr, $modelStr, $turnsInt, $projRoot)

    Set-Location $projRoot
    $promptText = Get-Content $tempFile -Raw -Encoding UTF8

    $args = @(
        "-p", $promptText,
        "--append-system-prompt-file", $promptFilePath,
        "--allowedTools", $toolsStr,
        "--max-turns", $turnsInt,
        "--output-format", "json",
        "--no-session-persistence",
        "--model", $modelStr
    )

    & claude @args 2>&1
} -ArgumentList $tempPromptFile, $promptFile, $tools, $Model, $MaxTurns, $projectRoot

# 타임아웃 대기
$completed = $job | Wait-Job -Timeout $TimeoutSeconds
$result = $null

if ($null -eq $completed) {
    # 타임아웃 — Job 강제 종료
    Write-Host "  [$AgentType] TIMEOUT (${TimeoutSeconds}s)" -ForegroundColor Red
    Stop-Job $job -Force
    Remove-Job $job -Force

    @{
        success = $false
        error   = "TIMEOUT after ${TimeoutSeconds}s"
        agent   = $AgentType
        model   = $Model
    } | ConvertTo-Json | Set-Content $OutputFile -Encoding UTF8
} else {
    # 정상 완료
    $result = Receive-Job $job
    $exitCode = $completed.ChildJobs[0].JobStateInfo.Reason

    if ($result) {
        # JSON 파싱 시도
        $resultStr = ($result | Out-String).Trim()
        $resultStr | Set-Content $OutputFile -Encoding UTF8
        Write-Host "  [$AgentType] 완료 → $OutputFile" -ForegroundColor Green
    } else {
        @{
            success = $false
            error   = "빈 결과"
            agent   = $AgentType
        } | ConvertTo-Json | Set-Content $OutputFile -Encoding UTF8
        Write-Host "  [$AgentType] 빈 결과 반환" -ForegroundColor Yellow
    }

    Remove-Job $job -Force
}

# 임시 파일 정리
Remove-Item $tempPromptFile -Force -ErrorAction SilentlyContinue
