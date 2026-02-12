@echo off
cls
setlocal EnableExtensions EnableDelayedExpansion

echo OpenCL Driver (ICD) Fix for AMD GPUs
echo Original work by Patrick Trumpis (https://github.com/ptrumpis/OpenCL-AMD-GPU)
echo Improvements by TantalusDrive (https://github.com/TantalusDrive)
echo Inspired by https://stackoverflow.com/a/28407851
echo.
echo.

REM ============================================================
REM Privilege check (robust, UAC-safe)
REM ============================================================
fsutil dirty query %systemdrive% >nul 2>&1
if errorlevel 1 goto :noAdmin
goto :continue

:noAdmin
echo.
echo Execution stopped
echo =================
echo This script requires administrator rights.
echo Please run it again as administrator.
echo You can right click the file and select 'Run as administrator'
echo.
pause
exit /b 1

:continue
echo Administrator privileges confirmed.
echo.

REM ============================================================
REM Detect Windows major version (robust, locale-safe)
REM ============================================================
set "WINVER=10"
for /f "tokens=1 delims=." %%v in ('wmic os get version ^| find "."') do (
    set "WINVER=%%v"
    goto :ver_ok
)
:ver_ok

echo Detected Windows major version: %WINVER%
echo.

REM ============================================================
REM Registry backup detection (Vista+ only)
REM ============================================================
set "REGBKOK=0"

if %WINVER% lss 6 (
    echo WARNING: Automatic registry backup not supported before Windows Vista.
    echo SAFE mode will be enforced.
) else (
    echo Checking automatic registry backup configuration...
    reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager" >nul 2>&1
    if not errorlevel 1 (
        reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager" ^
            /v EnablePeriodicBackup >nul 2>&1
        if not errorlevel 1 (
            reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager" ^
                /v EnablePeriodicBackup | findstr /I "0x0" >nul
            if errorlevel 1 (
                set "REGBKOK=1"
            )
        )
    )

    if "!REGBKOK!"=="0" (
        echo.
        echo WARNING: Automatic registry backup is not enabled.
        echo Destructive registry fixes will be disabled.
        echo.
        set "INPUT="
        set /P "INPUT=Do you want to enable it now? (Y/N): "
        if /I "!INPUT!"=="Y" (
            echo.
            echo Enabling automatic registry backup...
            reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager" ^
                /v EnablePeriodicBackup /t REG_DWORD /d 1 /f >nul 2>&1
            if not errorlevel 1 (
                echo Backup registry mechanism enabled successfully.
                set "REGBKOK=1"
            ) else (
                echo Failed to enable backup.
                echo Proceeding in SAFE mode only.
            )
        ) else (
            echo.
            echo Backup not enabled by user.
            echo Proceeding in SAFE mode only.
        )
    )

    echo.
    if "!REGBKOK!"=="1" (
        echo Registry backup active.
        echo Full registry operations are allowed.
    ) else (
        echo Registry backup inactive.
        echo SAFE mode active: registry writes will be skipped.
    )
)

echo.

REM ============================================================
REM Main script variables
REM ============================================================
set ROOTKEY64=HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors
set ROOTKEY32=HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Khronos\OpenCL\Vendors

REM ============================================================
REM Show current drivers
REM ============================================================
echo Currently installed OpenCL Client Drivers - 64bit
echo ==================================================
reg query "%ROOTKEY64%" >nul 2>&1 && (
    for /f "tokens=1,*" %%A in ('reg query "%ROOTKEY64%"') do echo %%A - %%B
) || echo (none)
echo.

echo Currently installed OpenCL Client Drivers - 32bit
echo ==================================================
reg query "%ROOTKEY32%" >nul 2>&1 && (
    for /f "tokens=1,*" %%A in ('reg query "%ROOTKEY32%"') do echo %%A - %%B
) || echo (none)
echo.

REM ============================================================
REM User confirmation
REM ============================================================
echo This script will now attempt to find and register unregistered AMD OpenCL drivers.
echo.
set "INPUT="
set /P "INPUT=Do you want to continue? (Y/N): "
if /I "!INPUT!" neq "Y" goto :exit
echo.
echo.

REM ============================================================
REM Fast Scan - standard locations
REM ============================================================
echo Running AMD OpenCL Driver Auto Detection
echo ========================================
echo.

for %%D in ("%SystemRoot%\System32" "%SystemRoot%\SysWOW64") do (
    if exist "%%~D" (
        echo Scanning '%%~D' for 'amdocl*.dll' files, please wait...
        echo.
        pushd "%%~D"
        call :registerMissingClientDriver
        popd
        echo.
    )
)

echo Fast Scan complete.
echo.
echo.

REM ============================================================
REM PATH scan
REM ============================================================
echo This script can now scan your PATH for additional AMD OpenCL drivers.
echo.
set "INPUT="
set /P "INPUT=Do you want to perform a Full PATH scan? (Y/N): "
if /I "!INPUT!" neq "Y" goto :complete
echo.
echo Now scanning PATH for 'amdocl*.dll' files, please wait...
echo.

for %%P in ("%PATH:;=" "%") do (
    if exist "%%~P" (
        pushd "%%~P" >nul 2>&1
        if not errorlevel 1 (
            call :registerMissingClientDriver
            popd
        )
    )
)

echo.
echo Full Scan complete.
echo.

:complete
echo Done.
echo.
pause
goto :exit

REM ============================================================
REM Register missing client drivers (non-destructive)
REM ============================================================
:registerMissingClientDriver
for /r %%F in (amdocl*.dll) do (
    set "FILE=%%~fF"
    set "NAME=%%~nxF"
    set "VALID="

    REM Accept AMD ICDs and versioned variants
    echo !NAME! | findstr /I "^amdocl" >nul && set "VALID=1"

    if defined VALID (
        echo Found: !FILE!

        REM Bitness heuristic (best possible in batch)
        set "ROOTKEY=!ROOTKEY32!"
        echo !NAME! | findstr /I "64" >nul && set "ROOTKEY=!ROOTKEY64!"

        REM Ensure root key exists
        reg query "!ROOTKEY!" >nul 2>&1
        if errorlevel 1 (
            reg add "!ROOTKEY!" /f >nul 2>&1
            echo Added Key: !ROOTKEY!
        )

        REM Register only if SAFE allows
        if "!REGBKOK!"=="1" (
            reg query "!ROOTKEY!" /v "!FILE!" >nul 2>&1
            if errorlevel 1 (
                reg add "!ROOTKEY!" /v "!FILE!" /t REG_DWORD /d 0 /f >nul 2>&1
                echo Registered: !FILE!
            ) else (
                echo Already present: !FILE!
            )
        ) else (
            echo SAFE mode active: registry write skipped for !FILE!
        )
        echo.
    )
)
goto :eof

:exit
exit /b 0
