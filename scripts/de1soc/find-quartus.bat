@ECHO off
REM Sets QUARTUS_BIN to the Quartus bin64 directory.
REM Uses QUARTUS_ROOTDIR if the installer set it, otherwise looks under D:\intelFPGA_lite and D:\altera_lite.
set QUARTUS_BIN=
if defined QUARTUS_ROOTDIR if exist "%QUARTUS_ROOTDIR%\bin64\quartus_stp.exe" set "QUARTUS_BIN=%QUARTUS_ROOTDIR%\bin64"
if not defined QUARTUS_BIN for /d %%D in ("D:\intelFPGA_lite\*" "D:\altera_lite\*") do if exist "%%~D\quartus\bin64\quartus_stp.exe" set "QUARTUS_BIN=%%~D\quartus\bin64"
if not defined QUARTUS_BIN (
	echo ERROR: Quartus not found. Install it with scripts\de1soc\install-quartus.ps1 or set QUARTUS_ROOTDIR.
	exit /b 1
)
echo Using Quartus in %QUARTUS_BIN%
exit /b 0
