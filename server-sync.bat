@echo off
setlocal EnableDelayedExpansion

REM =========================================================
REM  CONFIGURACION - EDITAR ESTAS RUTAS SI CAMBIAN
REM =========================================================

REM Carpeta de mods de tu instancia (origen)
set "ORIGEN=C:\Users\0_0\curseforge\minecraft\Instances\Guild 2.1 - copia\mods"

REM Carpeta de mods del servidor (destino)
set "DESTINO=C:\Games\Neo MC\mods"

REM Lista de mods prohibidos en el servidor (editala a mano)
REM OJO: la blacklist es SOLO para mods. A config no se le aplica.
set "BLACKLIST=%~dp0server-blacklist.txt"

REM Carpeta config de tu instancia (origen). Dejala VACIA para no tocar config.
set "CONFIG_ORIGEN=C:\Users\0_0\curseforge\minecraft\Instances\Guild 2.1 - copia\config"

REM Carpeta config del servidor (destino)
set "CONFIG_DESTINO=C:\Games\Neo MC\config"

REM Config que genera el PROPIO servidor y que tu instancia no tiene.
REM Sin esto, el espejo te borraria por ejemplo las tareas de pregeneracion
REM de Chunky. Separadas por coma; acepta carpetas o patrones con *.
REM Si queres un espejo puro (sin excepciones), dejala vacia.
set "CONFIG_CONSERVAR=chunky\tasks,worldedit\sessions,worldedit\.archive-unpack,*.bak"

REM =========================================================
REM  NO EDITAR DE ACA PARA ABAJO
REM
REM  Este script es independiente de sync-modpack.bat: NO corre
REM  packwiz, NO toca el repo del pack de los jugadores y NO toca
REM  nada fuera de las carpetas mods y config del servidor.
REM
REM  Uso:
REM    server-sync.bat           espeja mods + config al servidor
REM    server-sync.bat --list    solo lista como escribir cada mod
REM                              en la blacklist (no copia nada)
REM =========================================================

set "MOTOR=%~dp0server-sync.ps1"

REM --- Modo listado ---
if /i "%~1"=="--list" goto :modo_list
if /i "%~1"=="-l"     goto :modo_list
if /i "%~1"=="/list"  goto :modo_list
set "MODO="
goto :inicio

:modo_list
set "MODO=-ListOnly"

:inicio
echo.
echo ============================================
echo  Preparando mods del servidor
echo ============================================
echo Mods:      %ORIGEN%
echo        -^> %DESTINO%
if defined CONFIG_ORIGEN (
    echo Config:    %CONFIG_ORIGEN%
    echo        -^> %CONFIG_DESTINO%
) else (
    echo Config:    ^(desactivado^)
)
echo Blacklist: %BLACKLIST%
echo.

REM --- Verificar que exista todo antes de tocar nada ---
if not exist "%ORIGEN%" (
    echo [ERROR] No se encontro la carpeta de mods de origen:
    echo   %ORIGEN%
    echo Revisa la ruta ORIGEN al inicio de este script.
    goto :fin_error
)

if not exist "%DESTINO%" (
    echo [ERROR] No se encontro la carpeta de mods del servidor:
    echo   %DESTINO%
    echo Revisa la ruta DESTINO al inicio de este script.
    goto :fin_error
)

if defined CONFIG_ORIGEN (
    if not exist "%CONFIG_ORIGEN%" (
        echo [ERROR] No se encontro la carpeta config de origen:
        echo   %CONFIG_ORIGEN%
        echo Revisa CONFIG_ORIGEN al inicio de este script.
        goto :fin_error
    )
    if not exist "%CONFIG_DESTINO%" (
        echo [ERROR] No se encontro la carpeta config del servidor:
        echo   %CONFIG_DESTINO%
        echo Revisa CONFIG_DESTINO al inicio de este script.
        goto :fin_error
    )
)

if not exist "%BLACKLIST%" (
    echo [ERROR] No se encontro el archivo de blacklist:
    echo   %BLACKLIST%
    echo Sin blacklist no se corre nada: seria copiar TODO al server.
    goto :fin_error
)

if not exist "%MOTOR%" (
    echo [ERROR] Falta server-sync.ps1 junto a este .bat:
    echo   %MOTOR%
    goto :fin_error
)

REM --- Toda la logica vive en el .ps1 (batch puro no maneja bien
REM     el recorte de versiones en los nombres de archivo) ---
set "ARGS_CONFIG="
if defined CONFIG_ORIGEN set "ARGS_CONFIG=-SourceConfig "%CONFIG_ORIGEN%" -DestConfig "%CONFIG_DESTINO%" -KeepConfig "%CONFIG_CONSERVAR%""

powershell -NoProfile -ExecutionPolicy Bypass -File "%MOTOR%" -Source "%ORIGEN%" -Dest "%DESTINO%" -Blacklist "%BLACKLIST%" !ARGS_CONFIG! %MODO%
set "RC=!ERRORLEVEL!"

if "!RC!"=="0" goto :fin_ok

if "!RC!"=="1" (
    echo [ATENCION] La copia termino bien, pero hay avisos arriba.
    echo            Revisa la blacklist antes de arrancar el server.
    goto :fin_ok
)

if "!RC!"=="2" (
    echo.
    echo [ERROR] No se paso la validacion inicial ^(ver mensaje de arriba^).
    echo         No se copio ni borro nada: el server quedo intacto.
    goto :fin_error
)

if "!RC!"=="3" (
    echo.
    echo [ERROR] Fallo la copia y se revirtio ^(ver mensaje de arriba^).
    echo         La carpeta de mods del server quedo como estaba antes.
    goto :fin_error
)

if "!RC!"=="4" (
    echo.
    echo [ERROR] El script se corto por un error inesperado ^(ver arriba^).
    echo         Revisa la carpeta de mods del server antes de arrancarlo.
    goto :fin_error
)

echo.
echo [ERROR] Codigo de salida desconocido: !RC!
goto :fin_error

:fin_error
echo.
echo El script finalizo con errores.
pause
exit /b 1

:fin_ok
if defined MODO goto :sin_cartel
echo ============================================
if defined CONFIG_ORIGEN (
    echo  Listo. Los mods y la config del server estan al dia.
) else (
    echo  Listo. La carpeta de mods del server esta al dia.
)
echo ============================================
echo.
:sin_cartel
pause
exit /b 0
