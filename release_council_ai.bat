@echo off
setlocal

set SERVER_USER=yuta
set SERVER_HOST=160.251.207.11
set APP_DIR=/var/www/council-ai

echo ========================================
echo Council AI Release Launcher - Initial
echo ========================================
echo.
echo This will run deploy.sh on the server.
echo.
echo Server: %SERVER_USER%@%SERVER_HOST%
echo App Dir: %APP_DIR%
echo.

set /p CONFIRM=Run server deploy? [Y/N]: 

if /I not "%CONFIRM%"=="Y" (
  echo.
  echo Cancelled.
  pause
  exit /b 1
)

echo.
echo Connecting to server and running deploy.sh...
echo.

ssh %SERVER_USER%@%SERVER_HOST% "cd %APP_DIR% && cp deploy.sh /tmp/council_ai_deploy.sh && bash /tmp/council_ai_deploy.sh"

if %ERRORLEVEL% NEQ 0 (
  echo.
  echo ERROR: Deploy failed.
  pause
  exit /b 1
)

echo.
echo ========================================
echo Deploy completed successfully.
echo ========================================
pause