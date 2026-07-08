@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "FORCE=false"
if /I "%~1"=="--force" set "FORCE=true"
set "QWEN_CREDS=%USERPROFILE%\.qwen\oauth_creds.json"
set "SWE_ENV=%USERPROFILE%\.config\mini-swe-agent\.env"

if not exist "%QWEN_CREDS%" (
    echo ERR qwen-cli credentials not found at %QWEN_CREDS%
    echo Run qwen on a machine with a browser to authenticate first.
    exit /b 1
)

for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-Content $env:QWEN_CREDS -Raw | ConvertFrom-Json).access_token"`) do set "NEW_TOKEN=%%T"
if not defined NEW_TOKEN (
    echo ERR Could not extract access_token from %QWEN_CREDS%
    exit /b 1
)

if not exist "%USERPROFILE%\.config\mini-swe-agent" mkdir "%USERPROFILE%\.config\mini-swe-agent"
if not exist "%SWE_ENV%" (
    call :write_env
    echo OK Created new config at %SWE_ENV%
) else (
    powershell -NoProfile -Command "(Get-Content $env:SWE_ENV) -replace '^OPENAI_API_KEY=.*', ('OPENAI_API_KEY=' + $env:NEW_TOKEN) | Set-Content $env:SWE_ENV -Encoding UTF8"
    echo OK Token updated successfully
)

echo.
echo Testing token validity...
call :test_token
if not errorlevel 1 (
    echo OK Token is valid
    exit /b 0
)

echo WARN Token appears expired or invalid. Attempting qwen-cli refresh...
echo hi | qwen --no-stream >nul 2>nul
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-Content $env:QWEN_CREDS -Raw | ConvertFrom-Json).access_token"`) do set "NEW_TOKEN=%%T"
powershell -NoProfile -Command "(Get-Content $env:SWE_ENV) -replace '^OPENAI_API_KEY=.*', ('OPENAI_API_KEY=' + $env:NEW_TOKEN) | Set-Content $env:SWE_ENV -Encoding UTF8"
call :test_token
if errorlevel 1 (
    echo ERR Token still invalid after refresh
    exit /b 1
)
echo OK Refreshed token is valid
exit /b 0

:write_env
(
    echo OPENAI_API_KEY=%NEW_TOKEN%
    echo OPENAI_BASE_URL=https://portal.qwen.ai/v1
    echo MSWEA_MODEL_NAME=openai/coder-model
    echo MSWEA_CONFIGURED=true
    echo MSWEA_COST_TRACKING=ignore_errors
) > "%SWE_ENV%"
exit /b 0

:test_token
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$body=@{model='coder-model';messages=@(@{role='user';content='hi'});max_tokens=5}|ConvertTo-Json -Depth 5; try { Invoke-WebRequest -Uri 'https://portal.qwen.ai/v1/chat/completions' -Method Post -Headers @{Authorization=('Bearer ' + $env:NEW_TOKEN)} -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null; exit 0 } catch { exit 1 }"
exit /b %ERRORLEVEL%
