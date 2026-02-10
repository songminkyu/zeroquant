<#
.SYNOPSIS
  좀비 rust-analyzer / cargo 프로세스 정리
.DESCRIPTION
  VS Code가 사용 중인 최신 인스턴스는 유지하고,
  오래된 좀비 프로세스만 종료합니다.
.PARAMETER DryRun
  실제 종료 없이 정리 대상만 표시
.PARAMETER Register
  Windows Task Scheduler에 30분 간격 자동 실행 등록
.PARAMETER Unregister
  등록된 스케줄 태스크 제거
.EXAMPLE
  .\cleanup-rust-processes.ps1
  .\cleanup-rust-processes.ps1 -DryRun
  .\cleanup-rust-processes.ps1 -Register
  .\cleanup-rust-processes.ps1 -Unregister
#>
param(
    [switch]$DryRun,
    [switch]$Register,
    [switch]$Unregister
)

$TaskName = "ZeroQuant-RustAnalyzerCleanup"

# ===== Task Scheduler 등록/해제 =====
if ($Register) {
    $scriptPath = $PSCommandPath
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

    # 30분 간격 반복, 무기한 (365일 = 사실상 무기한, 매년 자동 갱신)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 365)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Settings $settings `
        -Description "ZeroQuant: 좀비 rust-analyzer 프로세스 30분 간격 자동 정리" `
        -Force | Out-Null

    Write-Host "✅ 스케줄 태스크 '$TaskName' 등록 완료 (30분 간격)" -ForegroundColor Green
    Write-Host "   확인: Get-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
    exit 0
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "✅ 스케줄 태스크 '$TaskName' 제거 완료" -ForegroundColor Green
    exit 0
}

# ===== 프로세스 정리 =====

$targets = @(
    @{ Name = "rust-analyzer"; Keep = 2 },
    @{ Name = "rust-analyzer-proc-macro-srv"; Keep = 2 }
)

$totalKilled = 0
$totalFreedMB = 0

foreach ($target in $targets) {
    $procs = Get-Process $target.Name -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending
    if (-not $procs -or $procs.Count -le $target.Keep) {
        Write-Host "[$($target.Name)] 정리 불필요 ($($procs.Count)개)" -ForegroundColor Green
        continue
    }

    $stale = $procs | Select-Object -Skip $target.Keep
    $freedMB = ($stale | ForEach-Object { $_.WorkingSet64 } | Measure-Object -Sum).Sum / 1MB

    Write-Host "`n[$($target.Name)] 전체 $($procs.Count)개, 유지 $($target.Keep)개, 정리 $($stale.Count)개 (~$([math]::Round($freedMB, 0))MB)" -ForegroundColor Yellow

    foreach ($p in $stale) {
        $age = (Get-Date) - $p.StartTime
        $info = "PID $($p.Id) | 시작: $($p.StartTime.ToString('MM-dd HH:mm')) | 경과: $([math]::Round($age.TotalHours, 1))h | $([math]::Round($p.WorkingSet64/1MB, 1))MB"

        if ($DryRun) {
            Write-Host "  [DRY-RUN] $info" -ForegroundColor Cyan
        } else {
            try {
                Stop-Process -Id $p.Id -Force
                Write-Host "  [종료됨] $info" -ForegroundColor Red
            } catch {
                Write-Host "  [실패] $info - $($_.Exception.Message)" -ForegroundColor Magenta
            }
        }
    }

    $totalKilled += $stale.Count
    $totalFreedMB += $freedMB
}

# 고아 rustc 프로세스 확인 (cargo 부모 없이 남은 것)
$orphanRustc = Get-Process rustc -ErrorAction SilentlyContinue | Where-Object {
    $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue
    if (-not $wmiProc -or -not $wmiProc.ParentProcessId) { return $true }
    $parentProc = Get-Process -Id $wmiProc.ParentProcessId -ErrorAction SilentlyContinue
    return (-not $parentProc)
}
if ($orphanRustc) {
    Write-Host "`n[rustc] 고아 프로세스 $($orphanRustc.Count)개 발견" -ForegroundColor Yellow
    foreach ($p in $orphanRustc) {
        if ($DryRun) {
            Write-Host "  [DRY-RUN] PID $($p.Id)" -ForegroundColor Cyan
        } else {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Host "  [종료됨] PID $($p.Id)" -ForegroundColor Red
            $totalKilled++
        }
    }
}

Write-Host "`n=== 완료: $totalKilled개 프로세스 정리, ~$([math]::Round($totalFreedMB, 0))MB 해제 ===" -ForegroundColor Green
