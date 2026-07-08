@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not defined SERVER set "SERVER=debian"
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "FORCE=false"
set "RESET=false"
set "SYNC_TOKEN=false"
set "STATUS=false"
set "COMPATIBLE=false"

for %%A in (%*) do (
    if /I "%%~A"=="--force" set "FORCE=true"
    if /I "%%~A"=="--reset" set "RESET=true"
    if /I "%%~A"=="--sync-token" set "SYNC_TOKEN=true"
    if /I "%%~A"=="--status" set "STATUS=true"
    if /I "%%~A"=="--compatible" set "COMPATIBLE=true"
    if /I "%%~A"=="--openrouter" set "COMPATIBLE=true"
)
if "%RESET%"=="true" set "FORCE=true"

echo ========================================
echo    AI Agent Deployment Script
echo ========================================

echo.
echo ==^> Checking server connectivity...
ssh -o ConnectTimeout=5 "%SERVER%" "echo OK" >nul 2>nul || (
    echo ERR Cannot connect to server "%SERVER%"
    exit /b 1
)
echo OK Connected to %SERVER%

if "%STATUS%"=="true" (
    echo.
    echo ==^> Server Status
    ssh "%SERVER%" "echo Session counter: $(cat ~/ai_home/state/session_counter.txt 2>/dev/null || echo N/A); echo Cron job: $(crontab -l 2>/dev/null | grep run_ai | head -1 || echo not set); echo Qwen token: $([ -f ~/.qwen/oauth_creds.json ] && echo present || echo missing); echo Agent config: $([ -f ~/.config/mini-swe-agent/.env ] && echo present || echo missing)"
    exit /b 0
)

if "%SYNC_TOKEN%"=="true" (
    echo.
    echo ==^> Syncing OAuth token...
    ssh "%SERVER%" "~/sync-qwen-token.sh --force"
    exit /b %ERRORLEVEL%
)

if "%COMPATIBLE%"=="true" (
    echo.
    echo ==^> Deploying OpenAI-compatible support files only...
    scp -q "%SCRIPT_DIR%\config\ai_agent_openrouter.yaml" "%SERVER%:~/live-swe-agent/config/ai_agent_openrouter.yaml" || exit /b 1
    scp -q "%SCRIPT_DIR%\setup-compatible.sh" "%SERVER%:~/setup-compatible.sh" || exit /b 1
    ssh "%SERVER%" "chmod +x ~/setup-compatible.sh"
    scp -q "%SCRIPT_DIR%\setup-openrouter.sh" "%SERVER%:~/setup-openrouter.sh" || exit /b 1
    ssh "%SERVER%" "chmod +x ~/setup-openrouter.sh"
    ssh "%SERVER%" "grep -q 'run_with_compatible' ~/run_ai.sh 2>/dev/null || cp ~/run_ai.sh ~/run_ai.sh.backup.$(date +%%Y%%m%%d_%%H%%M%%S) 2>/dev/null || true"
    ssh "%SERVER%" "grep -q 'run_with_compatible' ~/run_ai.sh 2>/dev/null" || scp -q "%SCRIPT_DIR%\run_ai.sh" "%SERVER%:~/run_ai.sh"
    ssh "%SERVER%" "chmod +x ~/run_ai.sh"
    echo OK OpenAI-compatible deployment complete
    exit /b 0
)

if "%FORCE%"=="true" if not "%RESET%"=="true" (
    echo WARN FORCE MODE: This will overwrite files the agent may have modified.
    set /p "CONFIRM=Are you sure? Type 'yes' to continue: "
    if not "!CONFIRM!"=="yes" exit /b 1
)

if "%RESET%"=="true" (
    echo WARN RESET MODE: This will destroy all agent state and modifications.
    set /p "CONFIRM=Are you absolutely sure? Type 'RESET' to continue: "
    if not "!CONFIRM!"=="RESET" exit /b 1
)

echo.
echo ==^> Deploying safe files...
scp -q "%SCRIPT_DIR%\config\ai_agent.yaml" "%SERVER%:~/live-swe-agent/config/ai_agent.yaml" || exit /b 1
scp -q "%SCRIPT_DIR%\config\ai_agent_openrouter.yaml" "%SERVER%:~/live-swe-agent/config/ai_agent_openrouter.yaml" || exit /b 1
scp -q "%SCRIPT_DIR%\setup-compatible.sh" "%SERVER%:~/setup-compatible.sh" || exit /b 1
scp -q "%SCRIPT_DIR%\setup-openrouter.sh" "%SERVER%:~/setup-openrouter.sh" || exit /b 1
scp -q "%SCRIPT_DIR%\sync-qwen-token.sh" "%SERVER%:~/sync-qwen-token.sh" || exit /b 1
ssh "%SERVER%" "chmod +x ~/setup-compatible.sh ~/setup-openrouter.sh ~/sync-qwen-token.sh"
echo OK Safe files deployed

if "%FORCE%"=="true" (
    echo.
    echo ==^> Force deploying agent-owned files...
    scp -q "%SCRIPT_DIR%\run_ai.sh" "%SERVER%:~/run_ai.sh" || exit /b 1
    scp -q "%SCRIPT_DIR%\SYSTEM_PROMPT.md" "%SERVER%:~/ai_home/SYSTEM_PROMPT.md" || exit /b 1
    scp -q "%SCRIPT_DIR%\ai_home\config.sh" "%SERVER%:~/ai_home/config.sh" || exit /b 1
    ssh "%SERVER%" "chmod +x ~/run_ai.sh"
)

if "%RESET%"=="true" (
    echo.
    echo ==^> Resetting remote state...
    ssh "%SERVER%" "rm -rf ~/ai_home/state ~/ai_home/logs ~/ai_home/knowledge ~/ai_home/projects ~/ai_home/tools && mkdir -p ~/ai_home/state ~/ai_home/logs ~/ai_home/knowledge ~/ai_home/projects ~/ai_home/tools && echo 0 > ~/ai_home/state/session_counter.txt"
)

echo OK Deployment complete
