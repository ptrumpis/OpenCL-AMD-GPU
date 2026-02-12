# This PowerShell script extends the original batch by safely cleaning up
# invalid or misplaced registry entries and coherently registering AMD
# OpenCL DLLs in the correct 32-bit or 64-bit hive, and providing detailed status output.
# By default, unsigned DLLs are allowed to prevent accidental removal.
#
# Risky registry operations are gated on evidence of registry backups (RegBack).
#
# Tested on older AMD GPUs (R5 M330, R5 M430). Feedback and contributions are welcome.
#
# Licensed under the MIT License.
# See LICENSE file in the repository root for full terms.

param(
    [switch]$AllowUnsigned
)

# preserve original default behaviour: unsigned allowed unless user explicitly passes -AllowUnsigned:$false
if (-not $PSBoundParameters.ContainsKey('AllowUnsigned')) {
    $AllowUnsigned = $true
} else {
    $AllowUnsigned = [bool]$AllowUnsigned
}

Write-Host "OpenCL Driver (ICD) Fix for AMD GPUs"
Write-Host "Original work by Patrick Trumpis (https://github.com/ptrumpis/OpenCL-AMD-GPU)"
Write-Host "Improvements by TantalusDrive (https://github.com/TantalusDrive)"
Write-Host "Inspired by https://stackoverflow.com/a/28407851"
Write-Host ""
Write-Host ""

# -------------------------
# Configuration
# -------------------------
$Roots = @{
    64 = "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors"
    32 = "HKLM:\SOFTWARE\WOW6432Node\Khronos\OpenCL\Vendors"
}

$ScanDirs = @(
    "$env:WINDIR\System32",
    "$env:WINDIR\SysWOW64",
    "$env:WINDIR\System32\DriverStore\FileRepository"
)

# -------------------------
# Counters and dedup
# -------------------------
[int]$countRemovedMissing = 0
[int]$countRemovedSignature = 0
[int]$countMoved = 0
[int]$countRegistered = 0
[int]$countAlready = 0
[int]$countDuplicates = 0
$Global:RegisteredSeen = [System.Collections.Generic.HashSet[string]]::new()
$hadErrors = $false

# -------------------------
# Helpers
# -------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RegistryBackupEnabled {
    $windir = $env:WINDIR
    if (-not $windir) { return $false }

    $regBackPath = Join-Path $windir "System32\config\RegBack"
    if (Test-Path $regBackPath) {
        $expected = @('SAM','SECURITY','SOFTWARE','SYSTEM','DEFAULT')
        try {
            foreach ($name in $expected) {
                $f = Join-Path $regBackPath $name
                if (-not (Test-Path $f)) { return $false }
                if ((Get-Item $f -ErrorAction SilentlyContinue).Length -le 0) { return $false }
            }
            return $true
        } catch { return $false }
    }

    try {
        # best-effort scheduled task check
        $task = Get-ScheduledTask -TaskName 'RegIdleBackup' -ErrorAction SilentlyContinue
        if ($task) { return $true }
        $task2 = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Registry\" -ErrorAction SilentlyContinue |
                 Where-Object { $_.TaskName -eq 'RegIdleBackup' }
        if ($task2) { return $true }
    } catch { }

    return $false
}

function Try-EnableRegistryBackup {
    if (-not (Test-IsAdmin)) {
        Write-Host "Administrator privileges required to enable registry backup automatically. Re-run as Administrator to allow automatic enabling." -ForegroundColor Yellow
        return $false
    }

    try {
        $cfgKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager"
        if (-not (Test-Path $cfgKey)) {
            New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "Configuration Manager" -Force -ErrorAction SilentlyContinue | Out-Null
        }
        New-ItemProperty -Path $cfgKey -Name "EnablePeriodicBackup" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Set EnablePeriodicBackup = 1 (attempted)." -ForegroundColor Cyan
    } catch {
        Write-Host "Failed to set EnablePeriodicBackup: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 1

    try {
        $task = Get-ScheduledTask -TaskName 'RegIdleBackup' -ErrorAction SilentlyContinue
        if (-not $task) {
            $task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Registry\" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq 'RegIdleBackup' }
        }
        if ($task) {
            try {
                Enable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
                Start-ScheduledTask  -InputObject $task -ErrorAction SilentlyContinue
                Write-Host "Triggered scheduled task 'RegIdleBackup' (if allowed)." -ForegroundColor Cyan
            } catch {
                Write-Host "Could not start/enable scheduled task 'RegIdleBackup' automatically: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Scheduled task 'RegIdleBackup' not found on this system." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Scheduled task check failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 4
    return (Test-RegistryBackupEnabled)
}

function Get-DllBitness {
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path,'Open','Read','Read')
        $br = New-Object IO.BinaryReader($fs)
        $fs.Seek(0x3C,'Begin') | Out-Null
        $pe = $br.ReadInt32()
        $fs.Seek($pe + 4,'Begin') | Out-Null
        $m = $br.ReadUInt16()
        $br.Close(); $fs.Close()
        switch ($m) {
            0x8664 { return 64 }
            0x014C { return 32 }
            default { return $null }
        }
    } catch { return $null }
}

function Is-AcceptableSignature {
    param($sig)
    if (-not $sig) { return $false }
    if ($sig.Status -eq 'Valid') { return $true }
    if ($AllowUnsigned -and ($sig.Status -eq 'NotSigned' -or $sig.Status -eq 'Unknown')) { return $true }
    return $false
}

function Ensure-Registry {
    param($bit, $dllPath)

    $root = $Roots[$bit]
    if ([string]::IsNullOrWhiteSpace($root)) { return }

    if (-not (Test-Path $root)) {
        try {
            New-Item -Path $root -Force | Out-Null
            Write-Host "Added Key: $root"
        } catch {
            Write-Host "Failed to create registry key: $root - $($_.Exception.Message)" -ForegroundColor Yellow
            $script:hadErrors = $true
            return
        }
    }

    if ($Global:RegisteredSeen.Contains($dllPath)) {
        $script:countDuplicates++
        Write-Host "Already present: $dllPath (duplicate skipped)"
        return
    }

    $props = (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue).PSObject.Properties
    $exists = $props | Where-Object { $_.Name -eq $dllPath } | Select-Object -First 1

    if ($exists) {
        $script:countAlready++
        Write-Host "Already present: $dllPath"
    } else {
        try {
            New-ItemProperty -Path $root -Name $dllPath -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            $script:countRegistered++
            Write-Host "Registered: $dllPath"
        } catch {
            # <<-- corrected parsing error by delimiting variables with ${}
            Write-Host "Failed to register ${dllPath} under ${root}: $($_.Exception.Message)" -ForegroundColor Yellow
            $script:hadErrors = $true
        }
    }

    $Global:RegisteredSeen.Add($dllPath) | Out-Null
}

# -------------------------
# Admin + RegBack gate (announce -> ask -> proceed)
# -------------------------
if (-not (Test-IsAdmin)) {
    Write-Host "Execution stopped" -ForegroundColor Red
    Write-Host "=================" -ForegroundColor Red
    Write-Host "This script requires administrator rights."
    Write-Host "Please run it again as administrator (right click the file and select 'Run as administrator')."
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Administrator privileges confirmed." -ForegroundColor Cyan
Write-Host ""

$RegistryBackupEnabled = Test-RegistryBackupEnabled
if ($RegistryBackupEnabled) {
    Write-Host "Registry backup active. Full registry operations are allowed." -ForegroundColor Green
} else {
    Write-Host "WARNING: Automatic registry backup is not enabled." -ForegroundColor Yellow
    $ans = Read-Host "Attempt to enable automatic registry backup now? This will try to set EnablePeriodicBackup and trigger RegIdleBackup. (Y/N)"
    if ($ans -match '^[Yy]$') {
        if (Try-EnableRegistryBackup) {
            $RegistryBackupEnabled = $true
            Write-Host "Registry backup active. Full registry operations are allowed." -ForegroundColor Green
        } else {
            Write-Host "Automatic enabling failed or RegBack files not created. Destructive registry operations will be SKIPPED." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Proceeding without enabling registry backups; destructive registry operations will be SKIPPED." -ForegroundColor Yellow
    }
}

# -------------------------
# Registry reconciliation (non-destructive unless $RegistryBackupEnabled)
# -------------------------
Write-Host ""
Write-Host "Scanning registry for invalid or misplaced entries..." -ForegroundColor Cyan

foreach ($bit in 64,32) {
    $root = $Roots[$bit]
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    if (-not (Test-Path $root)) { continue }

    $props = (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue).PSObject.Properties
    foreach ($p in $props) {
        $dll = $p.Name
        if ($dll -notlike "*amdocl*.dll") { continue }

        if (-not $RegistryBackupEnabled) {
            Write-Host "SAFE mode: skipped $dll" -ForegroundColor Yellow
            continue
        }

        if (-not (Test-Path $dll)) {
            Write-Host "Removed (missing): $dll" -ForegroundColor Yellow
            Remove-ItemProperty -Path $root -Name $dll -Force -ErrorAction SilentlyContinue
            $countRemovedMissing++
            continue
        }

        $sig = Get-AuthenticodeSignature -FilePath $dll -ErrorAction SilentlyContinue
        if (-not (Is-AcceptableSignature $sig)) {
            Write-Host "Removed (invalid signature): $dll" -ForegroundColor Yellow
            Remove-ItemProperty -Path $root -Name $dll -Force -ErrorAction SilentlyContinue
            $countRemovedSignature++
            continue
        }

        $realBit = Get-DllBitness $dll
        if ($realBit -and $realBit -ne $bit) {
            Write-Host "Moved ($($realBit) bit): $dll" -ForegroundColor Yellow
            Remove-ItemProperty -Path $root -Name $dll -Force -ErrorAction SilentlyContinue
            $countMoved++
            Ensure-Registry $realBit $dll
        }
    }
}

# -------------------------
# Register DLLs from standard locations
# -------------------------
Write-Host ""
Write-Host "This script will now attempt to find and install unregistered OpenCL AMD drivers (Fast Scan)."
$input = Read-Host "Do you want to continue? (Y/N)"
if ($input -ne 'Y' -and $input -ne 'y') {
    Write-Host "`nFast Scan skipped."
} else {
    Write-Host "`nRunning AMD OpenCL Driver Auto Detection"
    Write-Host "========================================"
    foreach ($dir in $ScanDirs) {
        if (-not (Test-Path $dir)) { continue }
        Write-Host "Scanning '$dir' for 'amdocl*.dll' files..."
        Get-ChildItem -Path $dir -Filter "amdocl*.dll" -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                $sig = Get-AuthenticodeSignature -FilePath $_.FullName -ErrorAction SilentlyContinue
                if (Is-AcceptableSignature $sig) {
                    $bit = Get-DllBitness $_.FullName
                    if ($bit) { Ensure-Registry $bit $_.FullName }
                }
            }
    }
    Write-Host "`nFast Scan complete." -ForegroundColor Cyan
}

# -------------------------
# Optional PATH scan (announce -> ask -> proceed)
# -------------------------
Write-Host ""
Write-Host "This script will now attempt a Full Scan (PATH)."
Write-Host "(Recommended only for custom or unofficial DLLs)" -ForegroundColor Yellow
$input = Read-Host "Do you want to continue? (Y/N)"
if ($input -ne 'Y' -and $input -ne 'y') {
    Write-Host "`nFull Scan skipped."
} else {
    Write-Host "`nNow scanning your PATH for 'amdocl*.dll' files, please wait..."
    Write-Host "Note: DLLs found in PATH may be unofficial or obsolete." -ForegroundColor Yellow
    Write-Host "==================================================="
    $pathDirs = ($env:PATH -split ';' | Where-Object { Test-Path $_ })
    foreach ($p in $pathDirs) {
        Write-Host "Scanning: $p"
        Get-ChildItem -Path $p -Filter "amdocl*.dll" -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                $sig = Get-AuthenticodeSignature -FilePath $_.FullName -ErrorAction SilentlyContinue
                if (Is-AcceptableSignature $sig) {
                    $bit = Get-DllBitness $_.FullName
                    if ($bit) { Ensure-Registry $bit $_.FullName }
                }
            }
    }
    Write-Host "`nFull Scan complete." -ForegroundColor Cyan
}

# -------------------------
# Summary
# -------------------------
Write-Host ""
Write-Host "========== SUMMARY =========="
Write-Host "Removed (missing)   : $countRemovedMissing"
Write-Host "Removed (signature) : $countRemovedSignature"
Write-Host "Moved entries       : $countMoved"
Write-Host "Registered new      : $countRegistered"
Write-Host "Already registered  : $countAlready"
Write-Host "Duplicates skipped  : $countDuplicates"
Write-Host "============================="
Write-Host ""

if ($hadErrors) {
    Write-Host "Completed with warnings." -ForegroundColor Yellow
} else {
    Write-Host "Completed." -ForegroundColor Green
}

Read-Host "Press Enter to exit"
