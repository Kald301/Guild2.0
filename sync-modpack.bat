@echo off
setlocal

REM =========================================================
REM  CONFIGURACION - EDITAR ESTAS RUTAS SI CAMBIAN
REM =========================================================

REM Carpeta raiz de tu instancia en CurseForge (origen)
set "ORIGEN=C:\Users\0_0\curseforge\minecraft\Instances\Guild 2.1 - copia"

REM Carpeta raiz de tu proyecto packwiz (destino)
set "DESTINO=C:\Users\0_0\Documents\GitHub\Guild2.0"

REM =========================================================
REM  NO EDITAR DE ACA PARA ABAJO
REM =========================================================

echo.
echo ============================================
echo  Sincronizando modpack desde CurseForge
echo ============================================
echo Origen:  %ORIGEN%
echo Destino: %DESTINO%
echo.

REM --- Verificar que las carpetas existan antes de tocar nada ---
if not exist "%ORIGEN%" (
    echo [ERROR] No se encontro la carpeta de origen:
    echo   %ORIGEN%
    echo Revisa la ruta ORIGEN al inicio de este script.
    goto :fin_error
)

if not exist "%DESTINO%" (
    echo [ERROR] No se encontro la carpeta de destino:
    echo   %DESTINO%
    echo Revisa la ruta DESTINO al inicio de este script.
    goto :fin_error
)

REM --- Sincronizar mods (solo .jar, espejo exacto) ---
echo [1/4] Sincronizando mods...
robocopy "%ORIGEN%\mods" "%DESTINO%\mods" *.jar /MIR /NFL /NDL /NJH /NJS
if %ERRORLEVEL% GEQ 8 goto :error_robocopy

REM --- Sincronizar config (espejo exacto) ---
echo [2/4] Sincronizando config...
if exist "%ORIGEN%\config" (
    robocopy "%ORIGEN%\config" "%DESTINO%\config" /MIR /NFL /NDL /NJH /NJS
    if %ERRORLEVEL% GEQ 8 goto :error_robocopy
) else (
    echo   (no existe carpeta config en origen, se omite)
)

REM --- Sincronizar kubejs (espejo exacto, si existe) ---
echo [3/4] Sincronizando kubejs...
if exist "%ORIGEN%\kubejs" (
    robocopy "%ORIGEN%\kubejs" "%DESTINO%\kubejs" /MIR /NFL /NDL /NJH /NJS
    if %ERRORLEVEL% GEQ 8 goto :error_robocopy
) else (
    echo   (no existe carpeta kubejs en origen, se omite)
)

REM --- Ejecutar packwiz para regenerar indices ---
echo [4/4] Actualizando indices de packwiz...
cd /d "%DESTINO%"
call packwiz curseforge detect
if errorlevel 1 goto :error_packwiz

call packwiz refresh
if errorlevel 1 goto :error_packwiz

echo.
echo ============================================
echo  Listo. Copia y deteccion completadas.
echo ============================================
echo.
echo Proximos pasos manuales:
echo   1. Revisa los cambios si queres (git status)
echo   2. git add .
echo   3. git commit -m "actualizacion de mods y configs"
echo   4. git push
echo.
goto :fin_ok

:error_robocopy
echo.
echo [ERROR] robocopy termino con codigo %ERRORLEVEL% ^(8 o mas indica error real,
echo         menor a 8 puede ser solo informativo, revisa el detalle arriba^).
goto :fin_error

:error_packwiz
echo.
echo [ERROR] packwiz devolvio un error. Revisa el mensaje de arriba.
goto :fin_error

:fin_error
echo.
echo El script finalizo con errores. No se hizo commit ni push.
pause
exit /b 1

:fin_ok
pause
exit /b 0
