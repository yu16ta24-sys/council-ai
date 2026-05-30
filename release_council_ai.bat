@echo off
setlocal enabledelayedexpansion

set REPO_DIR=C:\Users\ut\Desktop\council-ai
set SERVER_USER=yuta
set SERVER_HOST=160.251.207.11
set APP_DIR=/var/www/council-ai
set TEMP_DIR=%TEMP%\council_ai_update_work
set DELETE_BACKUP_DIR=%TEMP%\council_ai_delete_backup

echo ========================================
echo Council AI Release Launcher
echo ========================================
echo.

if "%~1"=="" (
  echo No update ZIP was provided.
  echo This mode will only run server deploy.
  echo.
  set MODE=2
  goto CONFIRM
)

set ZIP_FILE=%~1

echo Update ZIP:
echo %ZIP_FILE%
echo.

if /I not "%ZIP_FILE:~-4%"==".zip" (
  echo ERROR: This is not a .zip file.
  pause
  exit /b 1
)

echo [1/10] Cleaning temp folder...
if exist "%TEMP_DIR%" rmdir /s /q "%TEMP_DIR%"
mkdir "%TEMP_DIR%"

if exist "%DELETE_BACKUP_DIR%" rmdir /s /q "%DELETE_BACKUP_DIR%"
mkdir "%DELETE_BACKUP_DIR%"

echo [2/10] Extracting ZIP...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%ZIP_FILE%' -DestinationPath '%TEMP_DIR%' -Force"
if %ERRORLEVEL% NEQ 0 (
  echo ERROR: Failed to extract ZIP.
  pause
  exit /b 1
)

if not exist "%TEMP_DIR%\UPDATE_MANIFEST.json" (
  echo ERROR: UPDATE_MANIFEST.json was not found.
  echo This is not a valid Council AI update package.
  pause
  exit /b 1
)

if not exist "%TEMP_DIR%\.council-ai-update" (
  echo ERROR: .council-ai-update was not found.
  echo This is not a valid Council AI update package.
  pause
  exit /b 1
)

echo [3/10] Checking update marker...
findstr /C:"COUNCIL_AI_UPDATE_PACKAGE" "%TEMP_DIR%\.council-ai-update" >nul
if %ERRORLEVEL% NEQ 0 (
  echo ERROR: Invalid .council-ai-update marker.
  pause
  exit /b 1
)

echo [4/10] Checking dangerous files and paths...

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$root='%TEMP_DIR%';" ^
  "$bad=@();" ^
  "$items=Get-ChildItem -LiteralPath $root -Recurse -Force;" ^
  "foreach($i in $items){" ^
  "  $rel=$i.FullName.Substring($root.Length).TrimStart('\','/');" ^
  "  $rel2=$rel -replace '\\','/';" ^
  "  if($rel2 -match '(^|/)\.env$'){$bad+=$rel2};" ^
  "  if($rel2 -match '(^|/)\.git(/|$)'){$bad+=$rel2};" ^
  "  if($rel2 -match '(^|/)vendor(/|$)'){$bad+=$rel2};" ^
  "  if($rel2 -match '(^|/)node_modules(/|$)'){$bad+=$rel2};" ^
  "  if($rel2 -match '(^|/)storage/logs(/|$)'){$bad+=$rel2};" ^
  "  if($rel2 -match '(^|/)bootstrap/cache(/|$)'){$bad+=$rel2};" ^
  "  if($rel2 -match '\.\.'){$bad+=$rel2};" ^
  "  if($rel2 -match '^[A-Za-z]:'){$bad+=$rel2};" ^
  "  if($rel2 -match '^/var/'){$bad+=$rel2};" ^
  "}" ^
  "if($bad.Count -gt 0){" ^
  "  Write-Host 'ERROR: Dangerous files or paths were found:';" ^
  "  $bad | Sort-Object -Unique | ForEach-Object { Write-Host ('- ' + $_) };" ^
  "  exit 1;" ^
  "}"

if %ERRORLEVEL% NEQ 0 (
  echo.
  echo Update package rejected.
  pause
  exit /b 1
)

for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-Content '%TEMP_DIR%\UPDATE_MANIFEST.json' -Raw | ConvertFrom-Json).app_id"`) do set APP_ID=%%A
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-Content '%TEMP_DIR%\UPDATE_MANIFEST.json' -Raw | ConvertFrom-Json).version"`) do set UPDATE_VERSION=%%A
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-Content '%TEMP_DIR%\UPDATE_MANIFEST.json' -Raw | ConvertFrom-Json).from_version"`) do set FROM_VERSION=%%A
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-Content '%TEMP_DIR%\UPDATE_MANIFEST.json' -Raw | ConvertFrom-Json).summary"`) do set SUMMARY=%%A

if /I not "%APP_ID%"=="council-ai" (
  echo ERROR: app_id is not council-ai.
  echo app_id: %APP_ID%
  pause
  exit /b 1
)

if not exist "%REPO_DIR%\VERSION" (
  echo ERROR: Local VERSION file was not found.
  pause
  exit /b 1
)

set /p LOCAL_VERSION=<"%REPO_DIR%\VERSION"

if not "%LOCAL_VERSION%"=="%FROM_VERSION%" (
  echo ERROR: Version mismatch.
  echo.
  echo Local VERSION: %LOCAL_VERSION%
  echo ZIP from_version: %FROM_VERSION%
  echo ZIP version: %UPDATE_VERSION%
  echo.
  echo This update package cannot be applied.
  pause
  exit /b 1
)

echo.
echo ========================================
echo Manifest
echo ========================================
echo App ID: %APP_ID%
echo From version: %FROM_VERSION%
echo To version: %UPDATE_VERSION%
echo Summary: %SUMMARY%
echo ========================================
echo.

echo Delete targets:
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m=Get-Content '%TEMP_DIR%\UPDATE_MANIFEST.json' -Raw | ConvertFrom-Json; if($null -eq $m.delete -or $m.delete.Count -eq 0){Write-Host 'none'} else {$m.delete | ForEach-Object {Write-Host ('- ' + $_)}}"
echo.

echo Mode:
echo 1 = Git update only
echo 2 = Server deploy only
echo 3 = Git update + Server deploy [default]
echo.
set /p MODE=Select mode [1/2/3, Enter=3]: 

if "%MODE%"=="" set MODE=3

:CONFIRM
echo.
echo Selected mode: %MODE%
echo.
set /p CONFIRM=Run? [Y/N]: 

if /I not "%CONFIRM%"=="Y" (
  echo.
  echo Cancelled.
  pause
  exit /b 1
)

if "%MODE%"=="2" goto DEPLOY_ONLY

echo.
echo [5/10] Processing delete instructions...

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$repo='%REPO_DIR%';" ^
  "$manifest='%TEMP_DIR%\UPDATE_MANIFEST.json';" ^
  "$backup='%DELETE_BACKUP_DIR%';" ^
  "$m=Get-Content $manifest -Raw | ConvertFrom-Json;" ^
  "$deletes=@($m.delete);" ^
  "$bad=@();" ^
  "foreach($d in $deletes){" ^
  "  if([string]::IsNullOrWhiteSpace($d)){continue};" ^
  "  $p=($d -replace '\\','/').Trim();" ^
  "  if($p -match '\.\.' -or $p -match '^[A-Za-z]:' -or $p -match '^/' -or $p -match '^/var/'){$bad+=$p; continue};" ^
  "  if($p -match '(^|/)\.env$' -or $p -match '(^|/)\.git(/|$)' -or $p -match '(^|/)vendor(/|$)' -or $p -match '(^|/)node_modules(/|$)' -or $p -match '(^|/)storage/logs(/|$)' -or $p -match '(^|/)bootstrap/cache(/|$)'){$bad+=$p; continue};" ^
  "}" ^
  "if($bad.Count -gt 0){" ^
  "  Write-Host 'ERROR: Dangerous delete paths were found:';" ^
  "  $bad | Sort-Object -Unique | ForEach-Object { Write-Host ('- ' + $_) };" ^
  "  exit 1;" ^
  "}" ^
  "foreach($d in $deletes){" ^
  "  if([string]::IsNullOrWhiteSpace($d)){continue};" ^
  "  $p=($d -replace '/','\').Trim();" ^
  "  $target=Join-Path $repo $p;" ^
  "  if(Test-Path -LiteralPath $target){" ^
  "    $backupPath=Join-Path $backup $p;" ^
  "    $backupParent=Split-Path $backupPath -Parent;" ^
  "    New-Item -ItemType Directory -Force -Path $backupParent | Out-Null;" ^
  "    Copy-Item -LiteralPath $target -Destination $backupPath -Force;" ^
  "    Remove-Item -LiteralPath $target -Force;" ^
  "    Write-Host ('Deleted: ' + $d);" ^
  "  } else {" ^
  "    Write-Host ('Skip delete, not found: ' + $d);" ^
  "  }" ^
  "}"

if %ERRORLEVEL% NEQ 0 (
  echo.
  echo Delete processing failed.
  pause
  exit /b 1
)

echo.
echo [6/10] Applying files to local repo...

robocopy "%TEMP_DIR%" "%REPO_DIR%" /E /XD ".git" "vendor" "node_modules" "storage\logs" "bootstrap\cache" /XF ".env" "UPDATE_MANIFEST.json" ".council-ai-update"
if %ERRORLEVEL% GEQ 8 (
  echo ERROR: Failed to copy update files.
  pause
  exit /b 1
)

cd /d "%REPO_DIR%"

echo.
echo [7/10] Git status
git status

echo.
echo [8/10] Commit and push to GitHub
git add .
git commit -m "Update Council AI to v%UPDATE_VERSION% - %SUMMARY%"
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo No commit was created. There may be no file changes.
)

git push origin main
if %ERRORLEVEL% NEQ 0 (
  echo ERROR: git push failed.
  pause
  exit /b 1
)

if "%MODE%"=="1" (
  echo.
  echo Git update completed.
  pause
  exit /b 0
)

:DEPLOY_ONLY
echo.
echo [9/10] Running server deploy...
ssh %SERVER_USER%@%SERVER_HOST% "cd %APP_DIR% && cp deploy.sh /tmp/council_ai_deploy.sh && bash /tmp/council_ai_deploy.sh"

if %ERRORLEVEL% NEQ 0 (
  echo.
  echo ERROR: Deploy failed.
  pause
  exit /b 1
)

echo.
echo [10/10] Done
echo ========================================
echo Release completed successfully.
echo ========================================
pause