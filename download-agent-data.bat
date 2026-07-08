@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not defined SERVER set "SERVER=debian"
set "REMOTE_DIR=~/ai_home"
set "LOCAL_DIR=%CD%\tmp\agent_work"
set "DRY_RUN=false"
set "FORCE=false"

for %%A in (%*) do (
    if /I "%%~A"=="--dry-run" set "DRY_RUN=true"
    if /I "%%~A"=="--force" set "FORCE=true"
)

echo ========================================
echo    Agent Data Sync Script
echo ========================================
echo.

echo ==^> Checking server connectivity...
ssh -o ConnectTimeout=5 "%SERVER%" "echo OK" >nul 2>nul || (
    echo ERR Cannot connect to server "%SERVER%"
    exit /b 1
)
echo OK Connected to %SERVER%

if not exist "%LOCAL_DIR%" mkdir "%LOCAL_DIR%"

set RSYNC_OPTS=-avz --delete --exclude=.git/ --exclude=*.tmp --exclude=*.lock --exclude=.last_sync --itemize-changes
if "%DRY_RUN%"=="true" set RSYNC_OPTS=%RSYNC_OPTS% --dry-run
if "%FORCE%"=="true" set RSYNC_OPTS=%RSYNC_OPTS% --ignore-times

echo.
echo Sync Configuration:
echo   From: %SERVER%:%REMOTE_DIR%/
echo   To:   %LOCAL_DIR%/
echo   Mode: %DRY_RUN%
echo.

rsync %RSYNC_OPTS% -e ssh "%SERVER%:%REMOTE_DIR%/" "%LOCAL_DIR%/"
set "RSYNC_EXIT=%ERRORLEVEL%"

if "%RSYNC_EXIT%"=="0" goto :ok
if "%RSYNC_EXIT%"=="23" goto :ok
if "%RSYNC_EXIT%"=="24" goto :ok
echo ERR Rsync failed with exit code %RSYNC_EXIT%
exit /b %RSYNC_EXIT%

:ok
echo OK Sync operation complete
