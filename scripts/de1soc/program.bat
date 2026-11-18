@ECHO off
REM Program the DE1-SoC FPGA over the on-board USB-Blaster II (JTAG, volatile).
cd /d "%~dp0..\program"
call "%~dp0find-quartus.bat" || goto :end
"%QUARTUS_BIN%\quartus_stp.exe" -t program-fpga-board.tcl "%~dp0..\..\projects\DE1_SoC_Unoptimized_Pipelined\quartus_output\fpgaminer.sof"
:end
PAUSE
