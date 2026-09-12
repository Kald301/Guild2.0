@echo off
setlocal EnableDelayedExpansion

REM =========================================================
REM  CONFIGURACION - EDITAR ESTAS RUTAS SI CAMBIAN
REM =========================================================

REM Carpeta raiz de tu instancia en CurseForge (origen)
set "ORIGEN=C:\Users\0_0\curseforge\minecraft\Instances\Guild 2.1 - copia"

REM Carpeta raiz de tu proyecto packwiz (destino)
set "DESTINO=C:\Users\0_0\Documents\GitHub\Guild2.0"

REM Tamano maximo (MB) para convertir un mod a override automaticamente.
REM Por encima de esto se reporta para revision manual, para no chocar
REM con el limite de 100 MB por archivo de GitHub.
set "MAX_MB=90"

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

REM --- Ubicar packwiz (no siempre esta en el PATH: suele vivir en go\bin) ---
set "PACKWIZ="
for %%P in (packwiz.exe) do if not "%%~$PATH:P"=="" set "PACKWIZ=%%~$PATH:P"
if not defined PACKWIZ if exist "%USERPROFILE%\go\bin\packwiz.exe" set "PACKWIZ=%USERPROFILE%\go\bin\packwiz.exe"
if not defined PACKWIZ (
    echo [ERROR] No se encontro packwiz.exe ^(ni en el PATH ni en %USERPROFILE%\go\bin^).
    goto :fin_error
)

REM --- Sincronizar mods (solo .jar, espejo exacto) ---
echo [1/7] Sincronizando mods...
robocopy "%ORIGEN%\mods" "%DESTINO%\mods" *.jar /MIR /NFL /NDL /NJH /NJS
if %ERRORLEVEL% GEQ 8 goto :error_robocopy

REM --- Sincronizar config (espejo exacto) ---
echo [2/7] Sincronizando config...
if exist "%ORIGEN%\config" (
    robocopy "%ORIGEN%\config" "%DESTINO%\config" /MIR /NFL /NDL /NJH /NJS
    if %ERRORLEVEL% GEQ 8 goto :error_robocopy
) else (
    echo   (no existe carpeta config en origen, se omite)
)

REM --- Sincronizar kubejs (espejo exacto, si existe) ---
echo [3/7] Sincronizando kubejs...
if exist "%ORIGEN%\kubejs" (
    robocopy "%ORIGEN%\kubejs" "%DESTINO%\kubejs" /MIR /NFL /NDL /NJH /NJS
    if %ERRORLEVEL% GEQ 8 goto :error_robocopy
) else (
    echo   (no existe carpeta kubejs en origen, se omite)
)

REM --- Sincronizar resourcepacks (espejo exacto, si existe) ---
echo [4/7] Sincronizando resourcepacks...
if exist "%ORIGEN%\resourcepacks" (
    robocopy "%ORIGEN%\resourcepacks" "%DESTINO%\resourcepacks" /MIR /NFL /NDL /NJH /NJS
    if %ERRORLEVEL% GEQ 8 goto :error_robocopy
) else (
    echo   (no existe carpeta resourcepacks en origen, se omite)
)

REM --- Sincronizar shaderpacks (espejo exacto, si existe) ---
echo [5/7] Sincronizando shaderpacks...
if exist "%ORIGEN%\shaderpacks" (
    robocopy "%ORIGEN%\shaderpacks" "%DESTINO%\shaderpacks" /MIR /NFL /NDL /NJH /NJS
    if %ERRORLEVEL% GEQ 8 goto :error_robocopy
) else (
    echo   (no existe carpeta shaderpacks en origen, se omite)
)

REM --- Ejecutar packwiz para regenerar indices ---
echo [6/7] Actualizando indices de packwiz...
cd /d "%DESTINO%"
call "%PACKWIZ%" curseforge detect
if errorlevel 1 goto :error_packwiz

call "%PACKWIZ%" refresh
if errorlevel 1 goto :error_packwiz

REM =========================================================
REM  PASO 7: VERIFICACION DE DESCARGA REAL (detecta mods bloqueados)
REM
REM  Toda la logica vive en verify-mods.ps1 (PowerShell da control real
REM  de procesos, codigos de salida y manejo de archivos; el .bat puro
REM  no). Ya NO se usa "packwiz serve": el installer se corre directo
REM  contra el pack.toml local, asi que no hay servidor en segundo
REM  plano que pueda quedar colgado.
REM
REM  Codigos de salida de verify-mods.ps1:
REM    0 = la verificacion corrio y el pack quedo sano
REM    1 = corrio, arreglo lo que pudo, quedan casos manuales
REM    2 = NO se pudo verificar (falta java / falta el bootstrap jar)
REM    3 = la verificacion fallo de un modo no interpretable
REM    4 = el propio verificador se corto por un error inesperado
REM =========================================================
echo [7/7] Verificando que todos los mods sean descargables...
echo   (instala el pack entero en una carpeta de prueba: puede tardar)

if not exist "%DESTINO%\verify-mods.ps1" (
    echo.
    echo [ERROR] Falta verify-mods.ps1 en %DESTINO%
    echo         Sin ese archivo NO se puede verificar nada.
    goto :fin_error
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DESTINO%\verify-mods.ps1" -ProjectRoot "%DESTINO%" -SourceMods "%ORIGEN%\mods" -MaxMB %MAX_MB%
set "VERIF_RC=!ERRORLEVEL!"

if "!VERIF_RC!"=="0" goto :verif_fin
if "!VERIF_RC!"=="1" (
    echo.
    echo [ATENCION] Se arreglaron mods automaticamente pero quedaron casos
    echo            que necesitan revision manual. Mira mods-fallidos.txt
    echo            ANTES de hacer push.
    goto :verif_fin
)
if "!VERIF_RC!"=="2" (
    echo.
    echo [ERROR] La verificacion NO se pudo ejecutar ^(ver mensaje de arriba^).
    echo         No se probo nada: no asumas que el pack esta sano.
    goto :fin_error
)
if "!VERIF_RC!"=="4" (
    echo.
    echo [ERROR] El verificador se corto por un error propio ^(ver arriba^).
    echo         La prueba quedo a medias: no asumas que el pack esta sano.
    goto :fin_error
)

echo.
echo [ERROR] La verificacion fallo de forma inesperada ^(codigo !VERIF_RC!^).
echo         No se probo el pack completo: revisa el log indicado arriba.
goto :fin_error

:verif_fin

echo.
echo ============================================
echo  Listo. Copia, deteccion y verificacion completadas.
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
