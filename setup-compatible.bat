@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
if not defined COMPATIBLE_ENV set "COMPATIBLE_ENV=%SCRIPT_DIR%\.env"

set "API_KEY=%~1"
set "BASE_URL=%~2"
set "MODEL=%~3"

echo.
echo ==========================================
echo   Настройка OpenAI-compatible для ИИ-агента
echo ==========================================
echo.

if not defined API_KEY (
    set /p "API_KEY=Введите API key: "
)

if not defined BASE_URL (
    set /p "BASE_URL=Введите base URL [https://api.openai.com/v1]: "
    if not defined BASE_URL set "BASE_URL=https://api.openai.com/v1"
)

if not defined MODEL (
    set /p "MODEL=Введите модель [gpt-4o-mini]: "
    if not defined MODEL set "MODEL=gpt-4o-mini"
)

if not defined API_KEY (
    echo ERR API key не указан
    exit /b 1
)

if "%BASE_URL:~-1%"=="/" set "BASE_URL=%BASE_URL:~0,-1%"

echo -- Проверяю endpoint...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$body=@{model=$env:MODEL;messages=@(@{role='user';content='Ответь одним словом: привет.'});max_tokens=10}|ConvertTo-Json -Depth 5; try { Invoke-WebRequest -Uri ($env:BASE_URL + '/chat/completions') -Method Post -Headers @{Authorization=('Bearer ' + $env:API_KEY)} -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"

if errorlevel 1 (
    echo WARN Проверка endpoint не прошла.
    set /p "SAVE_ANYWAY=Сохранить эту конфигурацию все равно? [y/N] "
    if /I not "!SAVE_ANYWAY!"=="y" exit /b 1
) else (
    echo OK Endpoint доступен, ключ работает
)

for %%I in ("%COMPATIBLE_ENV%") do if not exist "%%~dpI" mkdir "%%~dpI"

echo -- Записываю конфигурацию в %COMPATIBLE_ENV%
(
    echo # OpenAI-compatible конфигурация для ИИ-агента
    echo # Сгенерировано setup-compatible.bat: %DATE% %TIME%
    echo.
    echo OPENAI_API_KEY=%API_KEY%
    echo OPENAI_BASE_URL=%BASE_URL%
    echo COMPATIBLE_MODEL=%MODEL%
    echo MSWEA_MODEL_NAME=openai/%MODEL%
    echo MSWEA_CONFIGURED=true
    echo MSWEA_COST_TRACKING=ignore_errors
) > "%COMPATIBLE_ENV%"

echo.
echo OK Конфигурация сохранена
echo.
echo Запусти одну сессию так:
echo.
echo run_ai.bat compatible
echo.
