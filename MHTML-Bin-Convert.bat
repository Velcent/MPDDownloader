@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MHTML-Bin-Convert.ps1" %*
