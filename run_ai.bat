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

set "STATE_DIR=%AI_HOME%\state"
set "SESSIONS_DIR=%SCRIPT_DIR%\.sessions"
set "CONFIG_FILE=%AI_HOME%\config.sh"
set "SESSION_COUNTER_FILE=%STATE_DIR%\session_counter.txt"
set "SESSION_TIMEOUT_SECONDS=1800"
if not defined AGENT_MAX_STEPS set "AGENT_MAX_STEPS=20"

call :load_env "%CONFIG_FILE%"
call :load_env "%PROJECT_ENV_FILE%"

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"
if not exist "%AI_HOME%\knowledge" mkdir "%AI_HOME%\knowledge"
if not exist "%AI_HOME%\projects" mkdir "%AI_HOME%\projects"
if not exist "%AI_HOME%\tools" mkdir "%AI_HOME%\tools"
if not exist "%SESSIONS_DIR%" mkdir "%SESSIONS_DIR%"

if not exist "%SESSION_COUNTER_FILE%" >"%SESSION_COUNTER_FILE%" echo 0
set /p CURRENT_SESSION=<"%SESSION_COUNTER_FILE%"
if not defined CURRENT_SESSION set "CURRENT_SESSION=0"
set /a NEXT_SESSION=CURRENT_SESSION+1 2>nul
if errorlevel 1 (
    set "CURRENT_SESSION=0"
    set "NEXT_SESSION=1"
)

echo Starting AI session #%NEXT_SESSION%
echo Run method: %METHOD% (timeout: %SESSION_TIMEOUT_SECONDS%s)

if /I "%METHOD%"=="compatible" call :run_agent
if /I "%METHOD%"=="openrouter" call :run_agent
if /I "%METHOD%"=="live-swe-agent" call :run_agent
if /I "%METHOD%"=="qwen" call :run_qwen
if /I "%METHOD%"=="api" call :run_api
set "RUN_EXIT=%ERRORLEVEL%"

if "%RUN_EXIT%"=="0" (
    call :archive_thoughts
    if errorlevel 1 exit /b 1
    call :archive_last_session
    if errorlevel 1 exit /b 1
)
exit /b %RUN_EXIT%

:archive_thoughts
if not exist "%SESSIONS_DIR%" mkdir "%SESSIONS_DIR%"
if not exist "%SESSIONS_DIR%\thought.md" (
    echo thought.md not found: %SESSIONS_DIR%\thought.md
    exit /b 1
)
echo Moving thought.md to .sessions\thoughts-%NEXT_SESSION%.md
move /Y "%SESSIONS_DIR%\thought.md" "%SESSIONS_DIR%\thoughts-%NEXT_SESSION%.md" >nul
exit /b %ERRORLEVEL%

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

:build_prompt
set "PROMPT_FILE=%TEMP%\ai_agent_prompt_%RANDOM%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$parts=New-Object System.Collections.Generic.List[string]; $parts.Add('=== SYSTEM PROMPT ==='); $parts.Add((Get-Content $env:SYSTEM_PROMPT_FILE -Raw -Encoding UTF8)); $parts.Add(''); $parts.Add('=== SESSION INFO ==='); $parts.Add('Session number: '+$env:NEXT_SESSION); $parts.Add(''); $parts.Add('=== CURRENT STATE ==='); $parts.Add(''); $parts.Add('--- session_counter.txt ---'); $parts.Add($env:CURRENT_SESSION); $parts.Add(''); foreach($name in @('current_plan.md','last_session.md','external_messages.md')){$p=Join-Path $env:STATE_DIR $name; $parts.Add('--- '+$name+' ---'); if(Test-Path $p){$parts.Add((Get-Content $p -Raw -Encoding UTF8))}else{$parts.Add('(empty)')}; $parts.Add('')}; $parts.Add('=== START ==='); $parts.Add('You woke up. This is session #'+$env:NEXT_SESSION+'.'); [IO.File]::WriteAllText($env:PROMPT_FILE, ($parts -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))"
exit /b 0

:run_agent
where python >nul 2>nul
if errorlevel 1 (
    echo Command not found: python
    echo Install Python or add it to PATH.
    exit /b 1
)
call :build_prompt
echo Using local Python agent: %AGENT_DIR%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $thought=Join-Path $env:SESSIONS_DIR 'thought.md'; python -B $env:AGENT_DIR --message-file $env:PROMPT_FILE --thought-file $thought --max-steps $env:AGENT_MAX_STEPS; exit $LASTEXITCODE"
set "EXIT_CODE=%ERRORLEVEL%"
del "%PROMPT_FILE%" >nul 2>nul
if "%EXIT_CODE%"=="0" >"%SESSION_COUNTER_FILE%" echo %NEXT_SESSION%
exit /b %EXIT_CODE%

:run_qwen
call :build_prompt
powershell -NoProfile -ExecutionPolicy Bypass -Command "$task=Get-Content $env:PROMPT_FILE -Raw -Encoding UTF8; qwen -p $task"
set "EXIT_CODE=%ERRORLEVEL%"
del "%PROMPT_FILE%" >nul 2>nul
exit /b %EXIT_CODE%

:run_api
echo Method api is not implemented in run_ai.bat. Use compatible.
exit /b 1