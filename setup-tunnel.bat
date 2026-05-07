@echo off
setlocal EnableDelayedExpansion

:: ─────────────────────────────────────────────
::  Cloudflare Tunnel Setup Script (Windows)
::  Cria tunnel + DNS via API (sem cloudflared login)
:: ─────────────────────────────────────────────

set "FULL_DOMAIN=sub.example.com"
set "CF_API_TOKEN="
set "CF_ACCOUNT_ID="
set "CF_ZONE_ID="

:: ─────────────────────────────────────────────

if "%FULL_DOMAIN%"=="sub.example.com" (
    echo [ERROR] Configure FULL_DOMAIN no script ^(ex: dev.meusite.com^).
    pause & exit /b 1
)
if "%CF_API_TOKEN%"=="" (
    echo [ERROR] Configure CF_API_TOKEN no script.
    pause & exit /b 1
)
if "%CF_ACCOUNT_ID%"=="" (
    echo [ERROR] Configure CF_ACCOUNT_ID no script.
    pause & exit /b 1
)
if "%CF_ZONE_ID%"=="" (
    echo [ERROR] Configure CF_ZONE_ID no script.
    pause & exit /b 1
)

echo.
echo ==========================================
echo    Cloudflare Tunnel Setup - Windows
echo ==========================================
echo.

:: ── Extract subdomain ─────────────────────────
for /f "tokens=1 delims=." %%s in ("%FULL_DOMAIN%") do set "SUBDOMAIN=%%s"
echo [OK]   Dominio: %FULL_DOMAIN% ^(subdominio: %SUBDOMAIN%^)

:: ── Ask for port ─────────────────────────────
set /p LOCAL_PORT="  Qual porta local expor? (ex: 3000): "
if "%LOCAL_PORT%"=="" (
    echo [ERROR] Porta nao pode ser vazia.
    pause & exit /b 1
)
echo [INFO]  Rota: https://%FULL_DOMAIN% -^> http://localhost:%LOCAL_PORT%
echo.

:: ── Check / install Node.js ───────────────────
echo [STEP]  Verificando Node.js...
where node >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN]  Node.js nao encontrado. Instalando via winget...
    winget install --id OpenJS.NodeJS.LTS -e --silent
    if %ERRORLEVEL% neq 0 (
        echo [ERROR] Nao foi possivel instalar Node.js automaticamente.
        echo         Instale manualmente em https://nodejs.org e execute novamente.
        pause & exit /b 1
    )
    for /f "tokens=*" %%p in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable(\"PATH\",\"Machine\")"') do set "PATH=%%p;%PATH%"
    echo [OK]   Node.js instalado.
) else (
    for /f "tokens=*" %%v in ('node --version') do echo [OK]   Node.js: %%v
)

:: ── Check / install PM2 ───────────────────────
echo [STEP]  Verificando PM2...
where pm2 >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN]  PM2 nao encontrado. Instalando...
    npm install -g pm2
    if %ERRORLEVEL% neq 0 (
        echo [ERROR] Falha ao instalar PM2.
        pause & exit /b 1
    )
) else (
    for /f "tokens=*" %%v in ('pm2 --version') do echo [OK]   PM2: %%v
)

:: ── Check / install cloudflared ───────────────
echo [STEP]  Verificando cloudflared...
where cloudflared >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN]  cloudflared nao encontrado. Instalando via winget...
    winget install --id Cloudflare.cloudflared -e --silent
    if %ERRORLEVEL% neq 0 (
        echo [WARN]  winget falhou. Tentando download direto...
        set "CF_EXE=%TEMP%\cloudflared.exe"
        powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile '%TEMP%\cloudflared.exe'"
        if not exist "%TEMP%\cloudflared.exe" (
            echo [ERROR] Nao foi possivel baixar cloudflared.
            pause & exit /b 1
        )
        copy /Y "%TEMP%\cloudflared.exe" "%SystemRoot%\cloudflared.exe" >nul
        echo [OK]   cloudflared instalado em %SystemRoot%\cloudflared.exe
    )
    for /f "tokens=*" %%p in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable(\"PATH\",\"Machine\")"') do set "PATH=%%p;%PATH%"
) else (
    for /f "tokens=*" %%v in ('cloudflared --version') do echo [OK]   cloudflared: %%v
)

:: ── Create or reuse Cloudflare Tunnel via API ─
set "TUNNEL_NAME=tunnel-%SUBDOMAIN%"
echo [STEP]  Verificando tunnel '%TUNNEL_NAME%'...

set "TMPFILE=%TEMP%\cf_tunnel_resp.json"

powershell -NoProfile -Command ^
  "$body = '{\"name\":\"%TUNNEL_NAME%\",\"tunnel_secret\":\"' + [Convert]::ToBase64String((1..32 | ForEach-Object { [byte](Get-Random -Max 256) })) + '\"}'; " ^
  "Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/accounts/%CF_ACCOUNT_ID%/cfd_tunnel' " ^
  "-Method POST -Headers @{Authorization='Bearer %CF_API_TOKEN%';'Content-Type'='application/json'} " ^
  "-Body $body | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 '%TMPFILE%'"

powershell -NoProfile -Command ^
  "$r = Get-Content '%TMPFILE%' | ConvertFrom-Json; " ^
  "if ($r.success) { $r.result.id | Out-File -Encoding utf8 '%TEMP%\cf_tunnel_id.txt' } " ^
  "else { $r.errors[0].code | Out-File -Encoding utf8 '%TEMP%\cf_tunnel_errcode.txt' }"

set /p TUNNEL_ID=<"%TEMP%\cf_tunnel_id.txt" 2>nul
if defined TUNNEL_ID (
    echo [OK]   Tunnel criado: ID=%TUNNEL_ID%
    del "%TEMP%\cf_tunnel_id.txt" >nul 2>&1
) else (
    set /p ERR_CODE=<"%TEMP%\cf_tunnel_errcode.txt" 2>nul
    del "%TEMP%\cf_tunnel_errcode.txt" >nul 2>&1
    if "!ERR_CODE!"=="1013" (
        echo [WARN]  Tunnel ja existe. Reutilizando...
        powershell -NoProfile -Command ^
          "$r = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/accounts/%CF_ACCOUNT_ID%/cfd_tunnel?name=%TUNNEL_NAME%&is_deleted=false' " ^
          "-Headers @{Authorization='Bearer %CF_API_TOKEN%'}; " ^
          "$r.result[0].id | Out-File -Encoding utf8 '%TEMP%\cf_tunnel_id.txt'"
        set /p TUNNEL_ID=<"%TEMP%\cf_tunnel_id.txt"
        del "%TEMP%\cf_tunnel_id.txt" >nul 2>&1
        if not defined TUNNEL_ID (
            echo [ERROR] Nao foi possivel obter o ID do tunnel existente.
            pause & exit /b 1
        )
        echo [OK]   Tunnel existente: ID=!TUNNEL_ID!
    ) else (
        echo [ERROR] Falha ao criar tunnel. Verifique CF_API_TOKEN e CF_ACCOUNT_ID.
        type "%TMPFILE%"
        pause & exit /b 1
    )
)
del "%TMPFILE%" >nul 2>&1

:: ── Get tunnel token ──────────────────────────
echo [STEP]  Obtendo token do tunnel...
powershell -NoProfile -Command ^
  "$r = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/accounts/%CF_ACCOUNT_ID%/cfd_tunnel/%TUNNEL_ID%/token' " ^
  "-Headers @{Authorization='Bearer %CF_API_TOKEN%'}; " ^
  "$r.result | Out-File -Encoding utf8 '%TEMP%\cf_tunnel_token.txt'"

set /p TUNNEL_TOKEN=<"%TEMP%\cf_tunnel_token.txt"
del "%TEMP%\cf_tunnel_token.txt" >nul 2>&1
if not defined TUNNEL_TOKEN (
    echo [ERROR] Falha ao obter token do tunnel.
    pause & exit /b 1
)
echo [OK]   Token do tunnel obtido.

:: ── Configure ingress rules via API ──────────
echo [STEP]  Configurando ingress do tunnel...
powershell -NoProfile -Command ^
  "$body = '{\"config\":{\"ingress\":[{\"hostname\":\"%FULL_DOMAIN%\",\"service\":\"http://localhost:%LOCAL_PORT%\"},{\"service\":\"http_status:404\"}]}}'; " ^
  "$r = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/accounts/%CF_ACCOUNT_ID%/cfd_tunnel/%TUNNEL_ID%/configurations' " ^
  "-Method PUT -Headers @{Authorization='Bearer %CF_API_TOKEN%';'Content-Type'='application/json'} " ^
  "-Body $body; " ^
  "if (-not $r.success) { Write-Error ($r.errors | ConvertTo-Json); exit 1 }"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Falha ao configurar ingress.
    pause & exit /b 1
)
echo [OK]   Ingress configurado.

:: ── Create or update DNS CNAME ────────────────
echo [STEP]  Configurando DNS CNAME: %FULL_DOMAIN%...
powershell -NoProfile -Command ^
  "$r = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/zones/%CF_ZONE_ID%/dns_records?type=CNAME&name=%FULL_DOMAIN%' " ^
  "-Headers @{Authorization='Bearer %CF_API_TOKEN%'}; " ^
  "$r.result[0].id | Out-File -Encoding utf8 '%TEMP%\cf_dns_id.txt'"

set /p EXISTING_DNS_ID=<"%TEMP%\cf_dns_id.txt" 2>nul
del "%TEMP%\cf_dns_id.txt" >nul 2>&1

if defined EXISTING_DNS_ID (
    echo [WARN]  Registro DNS ja existe. Atualizando...
    powershell -NoProfile -Command ^
      "$body = '{\"content\":\"%TUNNEL_ID%.cfargotunnel.com\",\"proxied\":true}'; " ^
      "$r = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/zones/%CF_ZONE_ID%/dns_records/%EXISTING_DNS_ID%' " ^
      "-Method PATCH -Headers @{Authorization='Bearer %CF_API_TOKEN%';'Content-Type'='application/json'} " ^
      "-Body $body; " ^
      "if (-not $r.success) { Write-Error ($r.errors | ConvertTo-Json); exit 1 }"
) else (
    powershell -NoProfile -Command ^
      "$body = '{\"type\":\"CNAME\",\"name\":\"%SUBDOMAIN%\",\"content\":\"%TUNNEL_ID%.cfargotunnel.com\",\"proxied\":true}'; " ^
      "$r = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/zones/%CF_ZONE_ID%/dns_records' " ^
      "-Method POST -Headers @{Authorization='Bearer %CF_API_TOKEN%';'Content-Type'='application/json'} " ^
      "-Body $body; " ^
      "if (-not $r.success) { Write-Error ($r.errors | ConvertTo-Json); exit 1 }"
)
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Falha ao configurar DNS.
    pause & exit /b 1
)
echo [OK]   DNS configurado: %FULL_DOMAIN%

:: ── Write PM2 ecosystem file ──────────────────
echo [STEP]  Criando configuracao PM2...
set "ECOSYSTEM_FILE=%USERPROFILE%\cf-tunnel-%SUBDOMAIN%.config.js"

(
echo module.exports = {
echo   apps: [{
echo     name: 'cf-tunnel-%SUBDOMAIN%',
echo     script: 'cloudflared',
echo     args: ['tunnel', '--no-autoupdate', 'run', '--token', '%TUNNEL_TOKEN%'],
echo     autorestart: true,
echo     watch: false,
echo     max_restarts: 10,
echo     restart_delay: 3000,
echo     env: {}
echo   }]
echo };
) > "%ECOSYSTEM_FILE%"
echo [OK]   Config PM2 escrita em: %ECOSYSTEM_FILE%

:: ── Start tunnel via PM2 ──────────────────────
echo [STEP]  Iniciando tunnel via PM2...
set "PM2_APP_NAME=cf-tunnel-%SUBDOMAIN%"
pm2 delete "%PM2_APP_NAME%" 2>nul
pm2 start "%ECOSYSTEM_FILE%"
pm2 save
echo [OK]   Tunnel iniciado no PM2.

:: ── Enable PM2 startup (Windows Service) ──────
echo [STEP]  Configurando PM2 para iniciar no boot...
pm2-startup install 2>nul || (
    echo [WARN]  pm2-startup nao encontrado. Instalando...
    npm install -g pm2-startup
    pm2-startup install
)

echo.
echo ==========================================
echo   Tunnel ativo!
echo ==========================================
echo.
echo   URL publica  : https://%FULL_DOMAIN%
echo   Porta local  : %LOCAL_PORT%
echo   Tunnel ID    : %TUNNEL_ID%
echo   PM2 app      : %PM2_APP_NAME%
echo.
echo Comandos uteis:
echo   pm2 logs %PM2_APP_NAME%      -- ver logs
echo   pm2 stop %PM2_APP_NAME%      -- parar tunnel
echo   pm2 restart %PM2_APP_NAME%   -- reiniciar tunnel
echo   pm2 delete %PM2_APP_NAME%    -- remover tunnel
echo.
pause
