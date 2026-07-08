@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not defined REMOTE_HOST set "REMOTE_HOST=debian"
set "LOCAL_CREDS=%USERPROFILE%\.qwen\oauth_creds.json"
set "REMOTE_CREDS=~/.qwen/oauth_creds.json"
set "NO_BROWSER=false"
if /I "%~1"=="--no-browser" set "NO_BROWSER=true"

if not exist "%LOCAL_CREDS%" (
    echo ERR Local qwen credentials not found at %LOCAL_CREDS%
    echo Run qwen to authenticate first.
    exit /b 1
)

for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-Content $env:LOCAL_CREDS -Raw | ConvertFrom-Json).access_token"`) do set "OLD_TOKEN=%%T"
echo Current token: %OLD_TOKEN:~0,20%...
echo.

echo Step 1: Refreshing token via qwen-cli...
echo test | qwen >nul 2>nul
if errorlevel 1 (
    echo WARN qwen-cli had issues, but token may still have refreshed
) else (
    echo OK qwen-cli executed successfully
)

for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-Content $env:LOCAL_CREDS -Raw | ConvertFrom-Json).access_token"`) do set "NEW_TOKEN=%%T"
if "%OLD_TOKEN%"=="%NEW_TOKEN%" (
    echo WARN Token unchanged after refresh attempt
) else (
    echo OK Token changed: %NEW_TOKEN:~0,20%...
)
echo.

echo Step 2: Testing token validity...
call :test_token
if errorlevel 1 (
    echo ERR Token is invalid or expired
    if "%NO_BROWSER%"=="true" exit /b 1
    set /p "AUTH=Would you like to try authenticating now? [y/N] "
    if /I "!AUTH!"=="y" (
        qwen
        for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-Content $env:LOCAL_CREDS -Raw | ConvertFrom-Json).access_token"`) do set "NEW_TOKEN=%%T"
        call :test_token || exit /b 1
    ) else (
        exit /b 1
    )
) else (
    echo OK Token is VALID
)
echo.

echo Step 3: Copying token to remote server (%REMOTE_HOST%)...
scp -q "%LOCAL_CREDS%" "%REMOTE_HOST%:%REMOTE_CREDS%" || exit /b 1
echo OK Token copied to %REMOTE_HOST%
echo.

echo Step 4: Syncing token to live-swe-agent on %REMOTE_HOST%...
ssh "%REMOTE_HOST%" "~/sync-qwen-token.sh --force" || exit /b 1
echo.

echo Step 5: Clearing error flags...
ssh "%REMOTE_HOST%" "rm -f ~/ai_home/state/token_error.flag" 2>nul
echo OK Token refresh complete
exit /b 0

:test_token
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$body=@{model='coder-model';messages=@(@{role='user';content='hi'});max_tokens=1}|ConvertTo-Json -Depth 5; try { Invoke-WebRequest -Uri 'https://portal.qwen.ai/v1/chat/completions' -Method Post -Headers @{Authorization=('Bearer ' + $env:NEW_TOKEN)} -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null; exit 0 } catch { exit 1 }"
exit /b %ERRORLEVEL%
