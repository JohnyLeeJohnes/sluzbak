@echo off
rem Vytvori zastupce "GolemWatch" s ikonou v nabidce Start, na plose a v teto slozce.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GolemWatch.ps1" -Install
pause
