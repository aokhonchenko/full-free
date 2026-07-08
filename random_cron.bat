@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
if not defined PROJECT_ENV_FILE set "PROJECT_ENV_FILE=%SCRIPT_DIR%\.env"
if not defined AI_HOME set "AI_HOME=%SCRIPT_DIR%\ai_home"
set "SESSIONS_DIR=%SCRIPT_DIR%\.sessions"
set "LOG_FILE=%SESSIONS_DIR%\random_cron.log"

if not exist "%SESSIONS_DIR%" mkdir "%SESSIONS_DIR%"
call :load_env "%PROJECT_ENV_FILE%"
call :validate_delay_range
if errorlevel 1 exit /b 1

call :log "random_cron started. Delay range: %RANDOM_CRON_MIN_DELAY_SECONDS%..%RANDOM_CRON_MAX_DELAY_SECONDS% seconds"

:loop
call :log "Starting AI session via run_ai.bat default method"
call "%SCRIPT_DIR%\run_ai.bat"
set "SESSION_EXIT=!ERRORLEVEL!"
call :log "AI session finished with exit code !SESSION_EXIT!"

call :commit_changes "!SESSION_EXIT!"
call :next_delay
call :log "Next session delay: !DELAY_SECONDS! seconds"
timeout /t !DELAY_SECONDS! /nobreak >nul
goto loop

:load_env
set "ENV_FILE=%~1"
if not exist "%ENV_FILE%" exit /b 0
for /f "usebackq tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
    set "ENV_NAME=%%A"
    set "ENV_VALUE=%%B"
    call :set_env_line
)
exit /b 0

:set_env_line
if not defined ENV_NAME exit /b 0
if "%ENV_NAME:~0,1%"=="#" exit /b 0
if /I "%ENV_NAME:~0,7%"=="export " set "ENV_NAME=%ENV_NAME:~7%"
set "%ENV_NAME%=%ENV_VALUE%"
exit /b 0

:validate_delay_range
if not defined RANDOM_CRON_MIN_DELAY_SECONDS (
    call :log "ERROR: RANDOM_CRON_MIN_DELAY_SECONDS is not set in .env"
    exit /b 1
)
if not defined RANDOM_CRON_MAX_DELAY_SECONDS (
    call :log "ERROR: RANDOM_CRON_MAX_DELAY_SECONDS is not set in .env"
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$min=0; $max=0; if(-not [int]::TryParse($env:RANDOM_CRON_MIN_DELAY_SECONDS, [ref]$min)){exit 2}; if(-not [int]::TryParse($env:RANDOM_CRON_MAX_DELAY_SECONDS, [ref]$max)){exit 3}; if($min -lt 0 -or $max -lt $min){exit 4}; exit 0"
if errorlevel 4 (
    call :log "ERROR: invalid delay range. Expected 0 <= min <= max"
    exit /b 1
)
if errorlevel 3 (
    call :log "ERROR: RANDOM_CRON_MAX_DELAY_SECONDS must be an integer"
    exit /b 1
)
if errorlevel 2 (
    call :log "ERROR: RANDOM_CRON_MIN_DELAY_SECONDS must be an integer"
    exit /b 1
)
exit /b 0

:next_delay
set "DELAY_SECONDS="
for /f %%S in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$min=[int]$env:RANDOM_CRON_MIN_DELAY_SECONDS; $max=[int]$env:RANDOM_CRON_MAX_DELAY_SECONDS; Get-Random -Minimum $min -Maximum ($max + 1)"') do set "DELAY_SECONDS=%%S"
if not defined DELAY_SECONDS set "DELAY_SECONDS=%RANDOM_CRON_MIN_DELAY_SECONDS%"
exit /b 0

:commit_changes
set "SESSION_EXIT=%~1"
set "STATUS_FILE=%TEMP%\random_cron_git_status_%RANDOM%.tmp"
git -C "%SCRIPT_DIR%" status --porcelain > "%STATUS_FILE%" 2>&1
if errorlevel 1 (
    call :log "ERROR: git status failed"
    call :log_file "%STATUS_FILE%"
    del "%STATUS_FILE%" >nul 2>nul
    exit /b 1
)
for %%F in ("%STATUS_FILE%") do set "STATUS_SIZE=%%~zF"
if "%STATUS_SIZE%"=="0" (
    call :log "No working directory changes to commit"
    del "%STATUS_FILE%" >nul 2>nul
    exit /b 0
)
del "%STATUS_FILE%" >nul 2>nul

git -C "%SCRIPT_DIR%" add -A >nul 2>&1
if errorlevel 1 (
    call :log "ERROR: git add -A failed"
    exit /b 1
)
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "COMMIT_TS=%%T"
set "COMMIT_LOG=%TEMP%\random_cron_git_commit_%RANDOM%.tmp"
git -C "%SCRIPT_DIR%" commit -m "AI session !COMMIT_TS! exit !SESSION_EXIT!" > "!COMMIT_LOG!" 2>&1
if errorlevel 1 (
    call :log "ERROR: git commit failed"
    call :log_file "!COMMIT_LOG!"
    del "!COMMIT_LOG!" >nul 2>nul
    exit /b 1
)
del "!COMMIT_LOG!" >nul 2>nul
call :log "Committed working directory changes: AI session !COMMIT_TS! exit !SESSION_EXIT!"
exit /b 0

:log_file
set "FILE_TO_LOG=%~1"
if not exist "%FILE_TO_LOG%" exit /b 0
for /f "usebackq delims=" %%L in ("%FILE_TO_LOG%") do call :log "%%L"
exit /b 0

:log
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'"') do set "NOW=%%T"
echo [!NOW!] %~1
>>"%LOG_FILE%" echo [!NOW!] %~1
exit /b 0
