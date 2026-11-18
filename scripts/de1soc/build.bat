@ECHO off
REM Compile the DE1-SoC project. Output: projects\DE1_SoC_Unoptimized_Pipelined\quartus_output\fpgaminer.sof
cd /d "%~dp0..\..\projects\DE1_SoC_Unoptimized_Pipelined"
call "%~dp0find-quartus.bat" || goto :end
"%QUARTUS_BIN%\quartus_sh.exe" --flow compile fpgaminer
if errorlevel 1 (
	echo.
	echo BUILD FAILED - see the messages above.
	goto :end
)
echo.
echo Build finished. Check timing: quartus_output\fpgaminer.sta.summary should show no negative slack.
:end
PAUSE
