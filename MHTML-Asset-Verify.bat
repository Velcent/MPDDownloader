@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MHTML-Asset-Verify.ps1" %*
