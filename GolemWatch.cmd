@echo off
rem Spusti GolemWatch bez instalace. Zastupce s ikonou vytvori install.cmd.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GolemWatch.ps1"
