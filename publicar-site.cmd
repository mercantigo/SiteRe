@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\publicar-site.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Publicacao falhou. Veja a mensagem acima.
  pause
)
exit /b %EXIT_CODE%
