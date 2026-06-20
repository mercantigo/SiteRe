@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\publicar-site.ps1" %*
exit /b %ERRORLEVEL%
