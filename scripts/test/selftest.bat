@ECHO off
REM Hardware self-test. Program the board first (..\de1soc\program.bat).
cd /d "%~dp0"
call ..\de1soc\find-quartus.bat || goto :end
"%QUARTUS_BIN%\quartus_stp.exe" -t selftest.tcl
:end
PAUSE
