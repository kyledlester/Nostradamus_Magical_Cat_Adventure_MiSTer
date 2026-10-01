# Full Quartus compile of the Nostradamus core. Writes build/quartus.log and a summary.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [-QuartusBin C:\intelFPGA_lite\17.0\quartus\bin64]
param([string]$QuartusBin='C:\intelFPGA_lite\17.0\quartus\bin64')
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    if(!(Test-Path build)) { New-Item -ItemType Directory build | Out-Null }
    # Project rule (owner request): never start while another agent's/project's Quartus job is running
    # on this machine - concurrent fits compete for CPU and memory. Wait until they are gone.
    $others = { Get-CimInstance Win32_Process -Filter "Name like 'quartus%'" |
                Where-Object { $_.CommandLine -notmatch 'Nostradamus' } }
    $announced = $false
    while (& $others) {
        if (-not $announced) { "Waiting for other Quartus jobs: " + ((& $others | ForEach-Object { $_.CommandLine }) -join ' | '); $announced = $true }
        Start-Sleep 20
    }
    $t0=Get-Date
    $qsh=Join-Path $QuartusBin 'quartus_sh.exe'
    if ($MapOnly) {
        # Analysis & Synthesis only (quick front-end check)
        $qmap = Join-Path $QuartusBin 'quartus_map.exe'
        cmd /c "`"$qmap`" Nostradamus > build\quartus_map.log 2>&1"
        $rc=$LASTEXITCODE
        Select-String -Path build/quartus_map.log -Pattern '^Error' | Select-Object -First 20 | ForEach-Object { $_.Line }
        "MAP exit=$rc"
        return
    }
    cmd /c "`"$qsh`" --flow compile Nostradamus > build\quartus.log 2>&1"
    $rc=$LASTEXITCODE
    $mins=[math]::Round(((Get-Date)-$t0).TotalMinutes,1)
    "BUILD exit=$rc minutes=$mins" | Out-File -Encoding ascii build/build-summary.txt
    Select-String -Path output_files/Nostradamus.fit.summary -Pattern 'Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total DSP|Total PLLs' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Line.Trim() } | Tee-Object -Variable _t | Out-File -Append -Encoding ascii build/build-summary.txt; $_t
    if(Test-Path output_files/Nostradamus.sta.summary) {
        Get-Content output_files/Nostradamus.sta.summary | Select-String -Pattern 'Type|Slack|TNS' | ForEach-Object { $_.Line.Trim() } | Select-Object -First 24 | Tee-Object -Variable _t | Out-File -Append -Encoding ascii build/build-summary.txt; $_t
    }
    Select-String -Path build/quartus.log -Pattern '^Error' -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { $_.Line } | Tee-Object -Variable _t | Out-File -Append -Encoding ascii build/build-summary.txt; $_t
    if($rc -ne 0){ throw "Quartus compile failed ($rc)" }
    Get-Item output_files/Nostradamus.rbf | ForEach-Object { "RBF $($_.FullName) $($_.Length) bytes" } | Tee-Object -Variable _t | Out-File -Append -Encoding ascii build/build-summary.txt; $_t
} finally { Pop-Location }
