@ECHO off
REM Operator dashboard: http://127.0.0.1:8080  (add --demo to try it without a board)
cd /d "%~dp0"
start "" http://127.0.0.1:8080
python dashboard.py %*
PAUSE
