@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MHTML-Entity-Fix.ps1" %*

echo.
echo Selesai. Tekan tombol apa saja untuk menutup...
pause >nul
