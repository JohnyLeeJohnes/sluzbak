@echo off
rem Vytvori zastupce "Sluzbak" s ikonou v nabidce Start, na plose a v teto slozce.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sluzbak.ps1" -Install
pause
