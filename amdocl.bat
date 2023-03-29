@echo off
echo OpenCL fix for AMD GPU's
echo By Patrick Trumpis (https://github.com/ptrumpis/OpenCL-AMD-GPU)
echo Inspired by https://stackoverflow.com/a/28407851
echo:

%SYSTEMDRIVE%
cd %SYSTEMROOT%
cd system32

SET ROOTKEY=HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors

SETLOCAL EnableDelayedExpansion
FOR /r %%x IN (*amdocl*dll) DO (
	SET FILE="%%x"
	reg add %ROOTKEY% /v %%x /t REG_DWORD /d 0 /f

	IF !ERRORLEVEL! == 0 (
		echo Added: !FILE!
		echo:
	)
)
pause
