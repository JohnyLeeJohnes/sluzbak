@echo off
rem Spusti Sluzbak bez instalace. Zastupce s ikonou vytvori install.cmd.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sluzbak.ps1"
