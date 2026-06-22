@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove Unused.ps1" %*
