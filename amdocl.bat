@echo off
echo OpenCL fix for AMD GPU's
echo By Patrick Trumpis (https://github.com/ptrumpis/OpenCL-AMD-GPU)
echo Inspired by https://stackoverflow.com/a/28407851
echo:

>nul 2>&1 "%SYSTEMROOT%\System32\cacls.exe" "%SYSTEMROOT%\System32\config\system" && (
    goto :run
) || (
    echo Execution stopped
    echo ==================
    echo This script requires administrator rights.
    echo Please run it again as administrator.
    echo You can right click the file and select 'Run as administrator'

    echo:
    pause
    exit /b 1
)

:run
SET ROOTKEY=HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors

SETLOCAL EnableDelayedExpansion

echo Now scanning your PATH for amdocl.dll files, please wait...
echo:

for %%a in ("%path:;=";"%") do (
    if "%%~a" neq "" (
        cd /D %%a
        for /r %%f in (*amdocl*dll) do (
            set FILE="%%~dpnxf"
            echo Found: !FILE!

            reg query %ROOTKEY% /v !FILE! >nul 2>&1

            if not !ERRORLEVEL! == 0 (
                reg add %ROOTKEY% /v !FILE! /t REG_DWORD /d 0 /f

                IF !ERRORLEVEL! == 0 (
                    echo Added: !FILE!
                )
            )
        )
    )
)

echo:
echo Done.
echo:
pause
exit /b 0
