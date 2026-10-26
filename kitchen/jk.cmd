@echo off
rem Short way in for Jordan: jk status | jk approve -Id J3 | jk kill -All | jk doctor | jk demo
if /I "%~1"=="demo" ( pwsh -NoProfile -File "%~dp0demo.ps1" -Open & exit /b %ERRORLEVEL% )
pwsh -NoProfile -File "%~dp0kitchen.ps1" %*
