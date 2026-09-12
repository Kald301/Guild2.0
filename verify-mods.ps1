# =====================================================================
#  verify-mods.ps1  --  Paso 7 de sync-modpack.bat
#
#  Simula lo que le pasa a un jugador cuando abre el modpack: corre
#  packwiz-installer contra el pack.toml LOCAL (sin servidor HTTP) en
#  una carpeta descartable, detecta los mods que no se pueden bajar
#  (tipicamente los que el autor excluyo de la API de CurseForge) y los
#  convierte en override: borra su .pw.toml y deja el .jar real dentro
#  de mods\, copiandolo desde la instancia de CurseForge.
#
#  Repite el ciclo hasta que la instalacion de prueba termine limpia.
#
#  NO se invoca a mano: lo llama sync-modpack.bat.
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ProjectRoot,
    [Parameter(Mandatory = $true)][string] $SourceMods,
    [int] $MaxMB     = 90,
    [int] $MaxRounds = 4
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Cualquier error inesperado tiene que salir con un codigo PROPIO (4).
# Si saliera con 1 el .bat lo confundiria con "arreglado a medias" y te
# diria que todo mas o menos anduvo, que es justo el bug que hubo antes.
trap {
    Write-Host ''
    Write-Host '  [ERROR] La verificacion se corto por un error inesperado:' -ForegroundColor Red
    Write-Host "          $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host "          (verify-mods.ps1 linea $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
    }
    Write-Host '  NO se pudo comprobar que el pack este sano.' -ForegroundColor Red
    exit 4
}

# ---------------------------------------------------------------------
#  Utilidades
# ---------------------------------------------------------------------

function Write-Step  ([string] $m) { Write-Host "  $m" }
function Write-Warn  ([string] $m) { Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Write-Fail  ([string] $m) { Write-Host "  [ERROR] $m" -ForegroundColor Red }

# packwiz no siempre esta en el PATH (suele vivir en %USERPROFILE%\go\bin)
function Resolve-Packwiz {
    $cmd = Get-Command packwiz.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:USERPROFILE 'go\bin\packwiz.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw "No se encontro packwiz.exe (ni en el PATH ni en $fallback)."
}

# Mata SOLO los procesos que dejo colgados una corrida anterior de la
# verificacion. Nunca toca un Minecraft ni un java del usuario: filtra
# por linea de comando.
function Stop-StaleVerifyProcesses {
    $patterns = @('packwiz-installer', 'packwiz.exe serve', 'packwiz serve')
    $killed = 0
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe' OR Name='packwiz.exe'" -ErrorAction Stop
    } catch {
        return 0
    }
    foreach ($p in $procs) {
        $cl = $p.CommandLine
        if ([string]::IsNullOrEmpty($cl)) { continue }
        foreach ($pat in $patterns) {
            if ($cl -like "*$pat*") {
                try {
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                    $killed++
                } catch { }
                break
            }
        }
    }
    return $killed
}

# Borra un directorio con reintentos (Windows tarda en soltar handles).
# Si despues de todo sigue bloqueado, devuelve $false en vez de reventar.
function Remove-DirHard ([string] $path) {
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    for ($i = 1; $i -le 5; $i++) {
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Milliseconds (250 * $i)
        }
    }
    return (-not (Test-Path -LiteralPath $path))
}

# ---------------------------------------------------------------------
#  Mapa  nombre-de-jar -> lista de .pw.toml que lo declaran
#
#  Puede haber mas de uno para el mismo .jar: por ejemplo si el mod ya
#  estaba agregado desde Modrinth y "packwiz curseforge detect" creo
#  ademas una copia apuntando a CurseForge. En ese caso el duplicado de
#  CurseForge es el que sobra.
# ---------------------------------------------------------------------
function Get-MetaList ([string] $modsDir) {
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($meta in (Get-ChildItem -LiteralPath $modsDir -Filter '*.pw.toml' -File -ErrorAction SilentlyContinue)) {
        $texto    = @(Get-Content -LiteralPath $meta.FullName)
        $filename = $null
        $esCF     = $false
        $tieneUrl = $false
        foreach ($line in $texto) {
            if (-not $filename -and $line -match '^\s*filename\s*=\s*"(.+)"\s*$') { $filename = $Matches[1] }
            if ($line -match '^\s*mode\s*=\s*"metadata:curseforge"\s*$')          { $esCF     = $true }
            if ($line -match '^\s*url\s*=\s*"')                                   { $tieneUrl = $true }
        }
        if (-not $filename) { continue }
        $lista.Add([pscustomobject]@{
            Jar      = $filename.ToLowerInvariant()
            Path     = $meta.FullName
            Nombre   = $meta.Name
            EsCF     = $esCF
            TieneUrl = $tieneUrl
        })
    }
    # OJO: sin la coma inicial. "return ,$arr" devolveria un array que
    # contiene al array, y el filtro de abajo terminaria matcheando todo.
    return $lista.ToArray()
}

# ---------------------------------------------------------------------
#  Extraer, del log del installer, los .jar que no se pudieron bajar
# ---------------------------------------------------------------------
function Get-FailedJars ([string] $logPath) {
    $jars = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $logPath)) { return $jars }

    foreach ($line in (Get-Content -LiteralPath $logPath)) {
        # Caso 1 (el habitual): mod excluido de la API de CurseForge.
        #   "... and save this file to C:\...\mods\loquesea.jar"
        if ($line -match 'save this file to\s+(.+\.jar)\s*$') {
            $jars.Add((Split-Path $Matches[1].Trim() -Leaf))
            continue
        }
        # Caso 2: hash invalido / fallo de descarga / URL muerta.
        # Se rescata cualquier nombre de .jar que aparezca en la linea.
        if ($line -match 'Hash invalid|Failed to download|RequestException|Unsupported download|FileNotFoundException|SocketTimeout') {
            foreach ($m in [regex]::Matches($line, '[^\s"''\\/:*?<>|]+\.jar')) {
                $jars.Add($m.Value)
            }
        }
    }
    return ($jars | Sort-Object -Unique)
}

# ---------------------------------------------------------------------
#  Arranque
# ---------------------------------------------------------------------

$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$modsDir     = Join-Path $ProjectRoot 'mods'
$packToml    = Join-Path $ProjectRoot 'pack.toml'
$reporte     = Join-Path $ProjectRoot 'mods-fallidos.txt'
$bootstrap   = Join-Path $ProjectRoot 'packwiz-installer-bootstrap.jar'

if (-not (Test-Path -LiteralPath $packToml)) { throw "No existe $packToml" }
if (-not (Test-Path -LiteralPath $modsDir))  { throw "No existe $modsDir" }

if (-not (Test-Path -LiteralPath $bootstrap)) {
    Write-Warn 'No se encontro packwiz-installer-bootstrap.jar junto al script.'
    Write-Warn 'Bajalo de https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest'
    Write-Warn 'NO se pudo verificar nada. El pack puede tener mods rotos.'
    exit 2
}

if (-not (Get-Command java.exe -ErrorAction SilentlyContinue)) {
    Write-Fail 'No se encontro java en el PATH. No se puede correr la verificacion.'
    Write-Fail 'NO se verifico nada. El pack puede tener mods rotos.'
    exit 2
}

$packwiz = Resolve-Packwiz

# Todo lo temporal vive fuera del repo, en LOCALAPPDATA.
$workRoot = Join-Path $env:LOCALAPPDATA 'packwiz-verify'
$instance = Join-Path $workRoot 'instance'
$cacheJar = Join-Path $workRoot 'packwiz-installer.jar'
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

# --- Limpieza robusta ANTES de empezar ---
$killed = Stop-StaleVerifyProcesses
if ($killed -gt 0) { Write-Step "Se cerraron $killed proceso(s) colgado(s) de una corrida anterior." }

if (-not (Remove-DirHard $instance)) {
    # Ultimo recurso: usar una carpeta nueva en vez de fallar como antes
    $instance = Join-Path $workRoot ("instance-" + (Get-Date -Format 'yyyyMMddHHmmss'))
    Write-Warn "La carpeta temporal anterior quedo bloqueada; se usa $instance"
}

$packUri = $packToml -replace '\\', '/'

$convertidos = New-Object System.Collections.Generic.List[object]
$manuales    = New-Object System.Collections.Generic.List[object]
$verificada  = $false
$limpio      = $false
$ultimoLog   = $null
$rondas      = 0

# ---------------------------------------------------------------------
#  Ciclo:  instalar de prueba -> arreglar fallos -> reintentar
# ---------------------------------------------------------------------
for ($ronda = 1; $ronda -le $MaxRounds; $ronda++) {
    $rondas = $ronda

    [void](Remove-DirHard $instance)
    New-Item -ItemType Directory -Force -Path $instance | Out-Null

    $outLog = Join-Path $instance 'installer-out.log'
    $errLog = Join-Path $instance 'installer-err.log'

    $jargs = @('-jar', $bootstrap, '-g', '--bootstrap-main-jar', $cacheJar, '-s', 'both', $packUri)

    Write-Step "Ronda $ronda : instalando el pack en una carpeta de prueba..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath 'java.exe' -ArgumentList $jargs `
                          -WorkingDirectory $instance -NoNewWindow -Wait -PassThru `
                          -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $sw.Stop()
    $exit = $proc.ExitCode

    # Un solo log unificado, guardado fuera del repo
    $ultimoLog = Join-Path $workRoot 'install.log'
    $texto = @()
    foreach ($f in @($outLog, $errLog)) {
        if (Test-Path -LiteralPath $f) { $texto += (Get-Content -LiteralPath $f) }
    }
    Set-Content -LiteralPath $ultimoLog -Value $texto -Encoding UTF8

    $verificada = $true   # la prueba REAL corrio (haya salido bien o mal)
    Write-Step ("Ronda {0} : el installer termino con codigo {1} en {2:N0}s" -f $ronda, $exit, $sw.Elapsed.TotalSeconds)

    if ($exit -eq 0) { $limpio = $true; break }

    $fallidos = @(Get-FailedJars $ultimoLog)

    if ($fallidos.Count -eq 0) {
        Write-Fail "El installer fallo (codigo $exit) pero no se pudo identificar ningun mod."
        Write-Fail "Esto NO es un 'todo OK': la verificacion no se pudo completar."
        Write-Fail "Log completo: $ultimoLog"
        exit 3
    }

    Write-Step "Ronda $ronda : $($fallidos.Count) mod(s) no se pudieron descargar."

    $metaList  = @(Get-MetaList $modsDir)
    $cambios   = 0

    foreach ($jar in $fallidos) {
        $key = $jar.ToLowerInvariant()
        $candidatos = @($metaList | Where-Object { $_.Jar -is [string] -and $_.Jar -eq $key })

        # Red de seguridad: un .jar no puede estar declarado por media
        # docena de .pw.toml. Si pasa, algo esta mal en el filtro y es
        # preferible frenar antes que borrar metadata de medio pack.
        if ($candidatos.Count -gt 3) {
            throw "Filtro roto: $jar coincidio con $($candidatos.Count) archivos .pw.toml. No se borra nada."
        }

        # --- Caso duplicado -------------------------------------------
        # El mismo .jar ya esta cubierto por otro .pw.toml que baja por
        # URL directa (tipicamente Modrinth). Entonces no hace falta
        # ningun override: alcanza con borrar la copia de CurseForge que
        # es la que falla.
        $conUrl = @($candidatos | Where-Object { $_.TieneUrl -and -not $_.EsCF })
        $soloCF = @($candidatos | Where-Object { $_.EsCF })
        if ($conUrl.Count -gt 0 -and $soloCF.Count -gt 0) {
            foreach ($dup in $soloCF) {
                Remove-Item -LiteralPath $dup.Path -Force
                $convertidos.Add([pscustomobject]@{
                    Jar  = $jar
                    Meta = $dup.Nombre
                    MB   = 0
                    Tipo = "duplicado borrado (ya lo cubre $($conUrl[0].Nombre))"
                })
                Write-Step "$jar -> se borro el duplicado de CurseForge $($dup.Nombre) (ya lo cubre $($conUrl[0].Nombre))"
                $cambios++
            }
            # si una corrida anterior habia dejado el .jar suelto, sobra
            $viejo = Join-Path $modsDir $jar
            if (Test-Path -LiteralPath $viejo) {
                Remove-Item -LiteralPath $viejo -Force
                Write-Step "$jar : se quito el .jar suelto que ya no hace falta."
            }
            continue
        }

        # De donde sacamos el .jar real: primero la instancia de CurseForge,
        # si no, el que ya pueda estar en mods\
        $origenJar = Join-Path $SourceMods $jar
        $destinoJar = Join-Path $modsDir $jar
        $fuente = $null
        if (Test-Path -LiteralPath $origenJar)      { $fuente = $origenJar }
        elseif (Test-Path -LiteralPath $destinoJar) { $fuente = $destinoJar }

        if (-not $fuente) {
            $manuales.Add([pscustomobject]@{ Jar = $jar; Motivo = 'no se encontro el .jar ni en la instancia de CurseForge ni en mods\'; MB = 0 })
            Write-Warn "$jar : no hay .jar disponible, requiere revision manual."
            continue
        }

        $mb = [math]::Round((Get-Item -LiteralPath $fuente).Length / 1MB, 2)

        if ($mb -gt $MaxMB) {
            $manuales.Add([pscustomobject]@{ Jar = $jar; Motivo = "archivo grande ($mb MB, limite $MaxMB MB) - no se convirtio para no romper el limite de 100 MB de GitHub"; MB = $mb })
            Write-Warn "$jar : $mb MB, supera $MaxMB MB. NO se convierte, requiere revision manual."
            continue
        }

        # 1) dejar el .jar fisico en mods\
        if ($fuente -ne $destinoJar) {
            Copy-Item -LiteralPath $fuente -Destination $destinoJar -Force
        }
        # 2) borrar el/los .pw.toml para que pase a ser override
        $borrados = @()
        foreach ($c in $candidatos) {
            $borrados += $c.Nombre
            Remove-Item -LiteralPath $c.Path -Force
        }

        if ($borrados.Count -eq 0) {
            $manuales.Add([pscustomobject]@{ Jar = $jar; Motivo = 'no se encontro el .pw.toml correspondiente (se copio el .jar igual)'; MB = $mb })
            Write-Warn "$jar : no se encontro su .pw.toml, revisar a mano."
            continue
        }

        $metaBorrado = ($borrados -join ', ')
        $convertidos.Add([pscustomobject]@{ Jar = $jar; Meta = $metaBorrado; MB = $mb; Tipo = 'convertido a override' })
        Write-Step "$jar -> override (se borro $metaBorrado, $mb MB)"
        $cambios++
    }

    if ($cambios -eq 0) {
        Write-Fail 'Hay mods que fallan pero ninguno se pudo arreglar automaticamente.'
        break
    }

    Write-Step 'Aplicando los cambios con packwiz refresh...'
    & $packwiz refresh | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "packwiz refresh fallo con codigo $LASTEXITCODE" }
}

# ---------------------------------------------------------------------
#  Reporte y limpieza
# ---------------------------------------------------------------------

[void](Remove-DirHard $instance)

if (-not $verificada) {
    Write-Fail 'La verificacion no llego a ejecutarse.'
    exit 2
}

if ($convertidos.Count -eq 0 -and $manuales.Count -eq 0) {
    if ($limpio) {
        Write-Host ''
        Write-Host "  VERIFICACION REAL COMPLETADA ($rondas ronda(s)): el installer instalo" -ForegroundColor Green
        Write-Host '  el pack entero sin un solo error. Todos los mods son descargables.' -ForegroundColor Green
    } else {
        Write-Fail 'La verificacion termino sin poder confirmar que el pack este sano.'
        Write-Fail "Log: $ultimoLog"
        exit 3
    }
    # (f) si no hay fallos no se deja ningun archivo suelto
    if (Test-Path -LiteralPath $reporte) { Remove-Item -LiteralPath $reporte -Force }
    exit 0
}

# --- Hubo fallos: escribir el reporte ---
$r = New-Object System.Collections.Generic.List[string]
$r.Add('============================================================')
$r.Add(' Reporte de verificacion de descarga - modpack Guild 2.0')
$r.Add(" Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$r.Add(" Rondas de verificacion: $rondas")
$r.Add('============================================================')
$r.Add('')

if ($convertidos.Count -gt 0) {
    $r.Add("MODS ARREGLADOS ($($convertidos.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add('Estos mods no se pueden bajar por la API de CurseForge (el autor')
    $r.Add('los excluyo). Hay dos arreglos posibles:')
    $r.Add('  - convertido a override: se borro su .pw.toml y el .jar real')
    $r.Add('    quedo dentro de mods\, asi se distribuye como archivo directo')
    $r.Add('    y no depende de ninguna API externa.')
    $r.Add('  - duplicado borrado: el mod ya estaba agregado desde otra fuente')
    $r.Add('    (Modrinth / URL directa) y solo sobraba la copia de CurseForge.')
    $r.Add('')
    foreach ($c in $convertidos) {
        $r.Add("  * $($c.Jar)")
        $r.Add("      accion           : $($c.Tipo)")
        $r.Add("      .pw.toml borrado : $($c.Meta)")
        if ($c.MB -gt 0) { $r.Add("      tamano           : $($c.MB) MB") }
    }
    $r.Add('')
}

if ($manuales.Count -gt 0) {
    $r.Add("REQUIERE REVISION MANUAL ($($manuales.Count))")
    $r.Add('------------------------------------------------------------')
    foreach ($m in $manuales) {
        $r.Add("  * $($m.Jar)")
        $r.Add("      motivo : $($m.Motivo)")
    }
    $r.Add('')
    $r.Add('Para los archivos grandes: subilos a Modrinth/otro host y agregalos')
    $r.Add('con "packwiz url add", o usa Git LFS. NO los subas tal cual: GitHub')
    $r.Add('rechaza archivos de mas de 100 MB.')
    $r.Add('')
}

if ($limpio) {
    $r.Add('RESULTADO FINAL: OK')
    $r.Add('Despues de los arreglos, la instalacion de prueba termino sin errores.')
} else {
    $r.Add('RESULTADO FINAL: CON PENDIENTES')
    $r.Add('La instalacion de prueba TODAVIA falla. Revisa los casos manuales.')
}
$r.Add('')
$r.Add("Log completo del installer: $ultimoLog")
$r.Add('')
$r.Add('NOTA: "packwiz curseforge detect" (paso 6) vuelve a convertir estos')
$r.Add('jars en metadata de CurseForge en cada sincronizacion. Por eso el')
$r.Add('paso 7 los vuelve a pasar a override automaticamente cada vez. Es')
$r.Add('esperado: no hace falta que hagas nada a mano.')

Set-Content -LiteralPath $reporte -Value $r -Encoding UTF8

Write-Host ''
if ($limpio) {
    Write-Host "  VERIFICACION REAL COMPLETADA ($rondas rondas): se arreglaron" -ForegroundColor Green
    Write-Host "  $($convertidos.Count) mod(s) y la instalacion de prueba final termino sin errores." -ForegroundColor Green
} else {
    Write-Warn 'Quedaron mods sin resolver. Revisa el reporte.'
}
Write-Host "  Detalle en: $reporte"

if ($limpio -and $manuales.Count -eq 0) { exit 0 } else { exit 1 }
