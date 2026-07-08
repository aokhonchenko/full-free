@echo off
setlocal EnableExtensions

set "METHOD=%~1"
if not defined METHOD set "METHOD=compatible"

set "VALID_METHOD="
for %%M in (compatible openrouter qwen live-swe-agent api) do (
    if /I "%METHOD%"=="%%M" set "VALID_METHOD=1"
)
if not defined VALID_METHOD (
    echo Unknown method: %METHOD%
    echo Usage: run_ai.bat compatible/openrouter/qwen/live-swe-agent/api
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
if not defined PROJECT_ENV_FILE set "PROJECT_ENV_FILE=%SCRIPT_DIR%\.env"
if not defined AI_HOME set "AI_HOME=%SCRIPT_DIR%\ai_home"
if not defined SYSTEM_PROMPT_FILE set "SYSTEM_PROMPT_FILE=%SCRIPT_DIR%\SYSTEM_PROMPT.md"
if not defined COMPATIBLE_ENV_FILE set "COMPATIBLE_ENV_FILE=%PROJECT_ENV_FILE%"
if not defined AGENT_DIR set "AGENT_DIR=%SCRIPT_DIR%\ai_home\projects\agent"

set "LOG_DIR=%AI_HOME%\logs"
set "STATE_DIR=%AI_HOME%\state"
set "SESSIONS_DIR=%SCRIPT_DIR%\.sessions"
set "CONFIG_FILE=%AI_HOME%\config.sh"
set "LOCK_FILE=%STATE_DIR%\session.lock"
set "SESSION_COUNTER_FILE=%STATE_DIR%\session_counter.txt"
set "SIMILARITY_CHECK_FILE=%STATE_DIR%\last_sessions_hash.txt"
set "REPETITION_THRESHOLD=5"
set "SESSION_TIMEOUT_SECONDS=1800"
if not defined AGENT_MAX_STEPS set "AGENT_MAX_STEPS=20"

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "TIMESTAMP=%%I"
for /f %%I in ('powershell -NoProfile -Command "$PID"') do set "RUNNER_PID=%%I"

call :load_env "%CONFIG_FILE%"
call :load_env "%PROJECT_ENV_FILE%"

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if not exist "%AI_HOME%\knowledge" mkdir "%AI_HOME%\knowledge"
if not exist "%AI_HOME%\projects" mkdir "%AI_HOME%\projects"
if not exist "%AI_HOME%\tools" mkdir "%AI_HOME%\tools"
if not exist "%SESSIONS_DIR%" mkdir "%SESSIONS_DIR%"

call :acquire_lock || exit /b 1

if not exist "%SESSION_COUNTER_FILE%" >"%SESSION_COUNTER_FILE%" echo 0
set /p CURRENT_SESSION=<"%SESSION_COUNTER_FILE%"
if not defined CURRENT_SESSION set "CURRENT_SESSION=0"
set /a NEXT_SESSION=CURRENT_SESSION+1 2>nul
if errorlevel 1 (
    set "CURRENT_SESSION=0"
    set "NEXT_SESSION=1"
)

call :log "Starting AI session #%NEXT_SESSION%"
call :check_repetition
if errorlevel 1 call :inject_randomness
call :log "Run method: %METHOD% (timeout: %SESSION_TIMEOUT_SECONDS%s)"

if /I "%METHOD%"=="compatible" call :run_agent
if /I "%METHOD%"=="openrouter" call :run_agent
if /I "%METHOD%"=="live-swe-agent" call :run_agent
if /I "%METHOD%"=="qwen" call :run_qwen
if /I "%METHOD%"=="api" call :run_api
set "RUN_EXIT=%ERRORLEVEL%"

call :release_lock
if "%RUN_EXIT%"=="0" (
    call :archive_last_session
    if errorlevel 1 exit /b 1
)
exit /b %RUN_EXIT%

:archive_last_session
if not exist "%SESSIONS_DIR%" mkdir "%SESSIONS_DIR%"
if not exist "%STATE_DIR%\last_session.md" (
    echo last_session.md not found: %STATE_DIR%\last_session.md
    exit /b 1
)
echo Saving last_session.md to .sessions\session-%NEXT_SESSION%.md
copy /Y "%STATE_DIR%\last_session.md" "%SESSIONS_DIR%\session-%NEXT_SESSION%.md" >nul
exit /b %ERRORLEVEL%
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

:log
>>"%LOG_DIR%\runner.log" echo [%TIMESTAMP%] %~1
exit /b 0

:acquire_lock
if exist "%LOCK_FILE%" (
    set /p LOCK_PID=<"%LOCK_FILE%"
    if defined LOCK_PID if /I not "%LOCK_PID%"=="released" (
        tasklist /FI "PID eq %LOCK_PID%" 2>nul | findstr /R "\<%LOCK_PID%\>" >nul
        if not errorlevel 1 (
            call :log "SKIP: previous session is still running (PID: %LOCK_PID%)"
            exit /b 1
        )
    )
)
>"%LOCK_FILE%" echo %RUNNER_PID%
call :log "Lock acquired"
exit /b 0

:release_lock
>"%LOCK_FILE%" echo released
call :log "Lock released"
exit /b 0

:check_repetition
powershell -NoProfile -ExecutionPolicy Bypass -Command "$state=$env:STATE_DIR; if(-not (Test-Path $state)){New-Item -ItemType Directory -Force -Path $state|Out-Null}; $file=Join-Path $state 'last_session.md'; $hist=$env:SIMILARITY_CHECK_FILE; $threshold=[int]$env:REPETITION_THRESHOLD; $content=''; if(Test-Path $file){$content=(Get-Content $file -Raw -Encoding UTF8) -replace '[Ss]ession [0-9]*','' -replace '[0-9]{4}-[0-9]{2}-[0-9]{2}',''}; $bytes=[Text.Encoding]::UTF8.GetBytes(($content -replace '\s+',' ')); $sha=[Security.Cryptography.SHA256]::Create(); try{$hashBytes=$sha.ComputeHash($bytes)}finally{$sha.Dispose()}; $hash=($hashBytes|ForEach-Object{$_.ToString('x2')}) -join ''; if(-not (Test-Path $hist)){Set-Content -Encoding ASCII $hist $hash; exit 0}; $items=@(Get-Content $hist -ErrorAction SilentlyContinue); $count=@($items|Where-Object{$_ -eq $hash}).Count; ($items+$hash|Select-Object -Last 10)|Set-Content -Encoding ASCII $hist; if($count -ge $threshold){exit 1}else{exit 0}"
if errorlevel 1 exit /b 1
exit /b 0

:inject_randomness
>>"%STATE_DIR%\external_messages.md" echo.
>>"%STATE_DIR%\external_messages.md" echo ---
>>"%STATE_DIR%\external_messages.md" echo.
>>"%STATE_DIR%\external_messages.md" echo ## System notice (%DATE% %TIME%)
>>"%STATE_DIR%\external_messages.md" echo.
>>"%STATE_DIR%\external_messages.md" echo LOOP BREAKER: the last sessions look too similar. Try a different move.
>>"%STATE_DIR%\external_messages.md" echo.
call :log "Added loop breaker message"
exit /b 0

:build_prompt
set "PROMPT_FILE=%TEMP%\ai_agent_prompt_%RANDOM%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$parts=New-Object System.Collections.Generic.List[string]; $parts.Add('=== SYSTEM PROMPT ==='); $parts.Add((Get-Content $env:SYSTEM_PROMPT_FILE -Raw -Encoding UTF8)); $parts.Add(''); $parts.Add('=== SESSION INFO ==='); $parts.Add('Session number: '+$env:NEXT_SESSION); $parts.Add(''); $parts.Add('=== CURRENT STATE ==='); $parts.Add(''); $parts.Add('--- session_counter.txt ---'); $parts.Add($env:CURRENT_SESSION); $parts.Add(''); foreach($name in @('current_plan.md','last_session.md','external_messages.md')){$p=Join-Path $env:STATE_DIR $name; $parts.Add('--- '+$name+' ---'); if(Test-Path $p){$parts.Add((Get-Content $p -Raw -Encoding UTF8))}else{$parts.Add('(empty)')}; $parts.Add('')}; $parts.Add('=== START ==='); $parts.Add('You woke up. This is session #'+$env:NEXT_SESSION+'.'); [IO.File]::WriteAllText($env:PROMPT_FILE, ($parts -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))"
exit /b 0

:run_agent
where python >nul 2>nul
if errorlevel 1 (
    echo Command not found: python
    echo Install Python or add it to PATH.
    call :log "ERROR: python command was not found in PATH"
    exit /b 1
)
call :build_prompt
call :log "Using local Python agent: %AGENT_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $log=Join-Path $env:LOG_DIR ('session_' + $env:TIMESTAMP + '.log'); $state=Join-Path $env:STATE_DIR 'agent_events.jsonl'; python -B $env:AGENT_DIR --message-file $env:PROMPT_FILE --state $state --max-steps $env:AGENT_MAX_STEPS 2>&1 | Tee-Object -FilePath $log -Append; exit $LASTEXITCODE"
set "EXIT_CODE=%ERRORLEVEL%"
del "%PROMPT_FILE%" >nul 2>nul
if "%EXIT_CODE%"=="0" >"%SESSION_COUNTER_FILE%" echo %NEXT_SESSION%
exit /b %EXIT_CODE%

:run_qwen
call :build_prompt
powershell -NoProfile -ExecutionPolicy Bypass -Command "$task=Get-Content $env:PROMPT_FILE -Raw -Encoding UTF8; qwen -p $task" 2>&1 | powershell -NoProfile -Command "$input | Tee-Object -FilePath (Join-Path $env:LOG_DIR ('session_' + $env:TIMESTAMP + '.log')) -Append"
set "EXIT_CODE=%ERRORLEVEL%"
del "%PROMPT_FILE%" >nul 2>nul
exit /b %EXIT_CODE%

:run_api
echo Method api is not implemented in run_ai.bat. Use compatible.
exit /b 1
