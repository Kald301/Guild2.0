# =====================================================================
#  verify-mods.ps1  --  Paso 7 de sync-modpack.bat
#
#  Hace tres cosas, en este orden:
#
#  1. DUPLICADOS CONOCIDOS (antes de instalar nada)
#     - un .jar suelto en mods\ que ya declara un .pw.toml: sobra el .jar
#     - el mismo .jar declarado por un .pw.toml de CurseForge Y por otro
#       que baja por URL directa (Modrinth): sobra el de CurseForge
#
#  2. PODA DE OBSOLETOS
#     Un .pw.toml cuyo .jar ya no esta en la instancia de CurseForge (ni
#     por nombre ni por hash) es un mod que sacaste de la instancia, o la
#     version vieja de uno que cambiaste por un fork. Ningun otro paso
#     los borra: "packwiz curseforge detect" solo agrega y robocopy solo
#     espeja .jar. Con -PruneMode listar solo se reportan; con borrar se
#     borran. mods-reemplazos.txt declara pares viejo -> nuevo y
#     mods-conservar.txt las excepciones que nunca se podan.
#
#  3. INSTALACION DE PRUEBA
#     Corre packwiz-installer contra el pack.toml LOCAL (sin servidor
#     HTTP) en una carpeta descartable y clasifica cada mod que falla:
#       - bloqueado por el autor (excluido de la API de CurseForge)
#           -> override: se borra su .pw.toml y el .jar real queda en
#              mods\, copiado desde la instancia de CurseForge
#       - error de red pasajero (sin conexion, 429, 5xx)
#           -> no se toca nada; se reintenta en la ronda siguiente
#       - cualquier otra cosa (hash invalido, 404, motivo desconocido)
#           -> NO se toca nada: queda para revision manual
#     Repite el ciclo hasta que la instalacion de prueba termine limpia.
#
#  NO se invoca a mano: lo llama sync-modpack.bat.
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ProjectRoot,
    [Parameter(Mandatory = $true)][string] $SourceMods,
    [int]    $MaxMB     = 90,
    [int]    $MaxRounds = 4,
    [string] $PruneMode = 'listar',
    [int]    $MaxPrune  = 10
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

# Se valida aca y no con ValidateSet: un error de parametros saldria
# con codigo 1, que el .bat leeria como "arreglado a medias".
if ($PruneMode -ne 'listar' -and $PruneMode -ne 'borrar') {
    throw "PruneMode invalido: '$PruneMode' (tiene que ser 'listar' o 'borrar'). Revisa PODA en sync-modpack.bat."
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

function Invoke-PackwizRefresh {
    Write-Step 'Aplicando los cambios con packwiz refresh...'
    & $packwiz refresh | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "packwiz refresh fallo con codigo $LASTEXITCODE" }
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

# Clave para comparar nombres de mod entre el .pw.toml y el log del
# installer: solo letras y numeros. Asi no importa si el log mezclo la
# codificacion de algun caracter raro (emojis, tildes).
function Get-NameKey ([string] $s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return ($s.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

# Lineas utiles de un .txt de configuracion (sin vacias ni comentarios #)
function Read-ListFile ([string] $path) {
    $out = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $t = ($line -split '#', 2)[0].Trim()
        if ($t -ne '') { $out.Add($t) }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------
#  Lista de .pw.toml de mods\ con lo que hace falta de cada uno
#
#  Puede haber mas de uno para el mismo .jar: por ejemplo si el mod ya
#  estaba agregado desde Modrinth y "packwiz curseforge detect" creo
#  ademas una copia apuntando a CurseForge. En ese caso el duplicado de
#  CurseForge es el que sobra.
# ---------------------------------------------------------------------
function Get-MetaList ([string] $modsDir) {
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($meta in (Get-ChildItem -LiteralPath $modsDir -Filter '*.pw.toml' -File -ErrorAction SilentlyContinue)) {
        $texto      = @(Get-Content -LiteralPath $meta.FullName -Encoding UTF8)
        $nombreMod  = $null
        $filename   = $null
        $hashFormat = $null
        $hash       = $null
        $esCF       = $false
        $tieneUrl   = $false
        foreach ($line in $texto) {
            if ($null -eq $nombreMod  -and $line -match '^\s*name\s*=\s*"(.*)"\s*$')        { $nombreMod  = $Matches[1] }
            if ($null -eq $filename   -and $line -match '^\s*filename\s*=\s*"(.+)"\s*$')    { $filename   = $Matches[1] }
            if ($null -eq $hashFormat -and $line -match '^\s*hash-format\s*=\s*"(.+)"\s*$') { $hashFormat = $Matches[1].ToLowerInvariant() }
            if ($null -eq $hash       -and $line -match '^\s*hash\s*=\s*"(.+)"\s*$')        { $hash       = $Matches[1].ToLowerInvariant() }
            if ($line -match '^\s*mode\s*=\s*"metadata:curseforge"\s*$')                     { $esCF       = $true }
            if ($line -match '^\s*url\s*=\s*"')                                              { $tieneUrl   = $true }
        }
        if (-not $filename) { continue }
        $lista.Add([pscustomobject]@{
            Jar        = $filename.ToLowerInvariant()
            Archivo    = $filename
            Path       = $meta.FullName
            Nombre     = $meta.Name
            Slug       = $meta.Name.Substring(0, $meta.Name.Length - '.pw.toml'.Length)
            ClaveMod   = (Get-NameKey $nombreMod)
            HashFormat = $hashFormat
            Hash       = $hash
            EsCF       = $esCF
            TieneUrl   = $tieneUrl
        })
    }
    # OJO: sin la coma inicial. "return ,$arr" devolveria un array que
    # contiene al array, y los filtros de abajo terminarian matcheando todo.
    return $lista.ToArray()
}

# ---------------------------------------------------------------------
#  La instancia de CurseForge es la fuente de verdad: un .pw.toml esta
#  vigente si su .jar esta ahi, por nombre o por el hash que declara.
#  Los hashes de la instancia se calculan solo si hace falta (un nombre
#  que no coincide) y una sola vez por algoritmo.
# ---------------------------------------------------------------------
$script:srcJars   = @()
$script:srcByName = @{}
$script:hashCache = @{}

function Test-EnInstancia ($meta) {
    if ($script:srcByName.ContainsKey($meta.Jar)) { return $true }
    $alg = $null
    switch ($meta.HashFormat) {
        'sha1'   { $alg = 'SHA1' }
        'sha256' { $alg = 'SHA256' }
        'sha512' { $alg = 'SHA512' }
        'md5'    { $alg = 'MD5' }
    }
    if (-not $alg -or -not $meta.Hash) { return $false }
    if (-not $script:hashCache.ContainsKey($alg)) {
        $tabla = @{}
        foreach ($j in $script:srcJars) {
            $tabla[(Get-FileHash -LiteralPath $j.FullName -Algorithm $alg).Hash.ToLowerInvariant()] = $j.Name
        }
        $script:hashCache[$alg] = $tabla
    }
    return $script:hashCache[$alg].ContainsKey($meta.Hash)
}

# "nuevo" de mods-reemplazos.txt esta en uso si es un .pw.toml vigente,
# o si en la instancia hay un .jar cuyo nombre empieza con "nuevo" y
# sigue con un separador (para reemplazos que son override).
function Test-ReemplazoPresente ([string] $nuevo, $metaPorSlug) {
    $p = $nuevo.ToLowerInvariant()
    $m = $metaPorSlug[$p]
    if ($null -ne $m -and (Test-EnInstancia $m)) { return $true }
    foreach ($j in $script:srcJars) {
        $n = $j.Name.ToLowerInvariant()
        if ($n.Length -gt $p.Length -and $n.StartsWith($p) -and '-_+.'.Contains([string]$n[$p.Length])) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------
#  Fallos del log del installer
#
#  packwiz-installer escribe una linea por archivo que falla:
#     "Failed to download <nombre del mod>: <motivo>"
#  donde <nombre del mod> es el campo name del .pw.toml (o el nombre de
#  archivo, si es un override). Si el mod esta excluido de la API de
#  CurseForge, el motivo sigue en la linea siguiente:
#     "Please go to <url> and save this file to <ruta>\mods\<jar>"
# ---------------------------------------------------------------------
function Get-InstallFailures ([string] $logPath) {
    $fallos = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $logPath)) { return @() }
    $ultimo = $null
    foreach ($line in (Get-Content -LiteralPath $logPath -Encoding UTF8)) {
        $i = $line.IndexOf('Failed to download ')
        if ($i -ge 0) {
            $resto = $line.Substring($i + 'Failed to download '.Length).Trim()
            # pack.toml / index file son errores fatales: se tratan aparte.
            # "modpack, the following errors were encountered:" es el
            # encabezado del resumen final, no un mod.
            if ($resto -match '^(pack\.toml|index file)\b')                  { continue }
            if ($resto -match '^modpack, the following errors were encountered') { continue }
            $ultimo = [pscustomobject]@{ Texto = $resto; Jar = $null; Extra = ''; Linea = $line.Trim() }
            # por si el "save this file to" vino en la misma linea
            if ($resto -match 'save this file to\s+(.+\.jar)\s*$') { $ultimo.Jar = Split-Path $Matches[1].Trim() -Leaf }
            $fallos.Add($ultimo)
            continue
        }
        if ($line -match 'save this file to\s+(.+\.jar)\s*$') {
            $jar = Split-Path $Matches[1].Trim() -Leaf
            if ($null -ne $ultimo -and $null -eq $ultimo.Jar -and $ultimo.Texto -match 'excluded from the CurseForge API') {
                $ultimo.Jar   = $jar
                $ultimo.Extra = $line.Trim()
            } else {
                $fallos.Add([pscustomobject]@{
                    Texto = "${jar}: This mod is excluded from the CurseForge API"
                    Jar   = $jar
                    Extra = $line.Trim()
                    Linea = $line.Trim()
                })
            }
        }
    }
    return $fallos.ToArray()
}

function Get-FailureKind ([string] $m) {
    if ($m -match 'excluded from the CurseForge API|save this file to')         { return 'bloqueado' }
    if ($m -match 'error code from HTTP request:\D*(408|425|429|5\d\d)\b')        { return 'transitorio' }
    if ($m -match 'Failed to make HTTP request|Internal fatal HTTP request error|HTTP request failed|must have a response body|[Tt]imed? ?out|Timeout|Connection reset|UnknownHost|ConnectException|SocketException|SSLException|EOFException') {
        return 'transitorio'
    }
    if ($m -match 'Hash invalid')                                                 { return 'hash' }
    if ($m -match 'error code from HTTP request')                                 { return 'http' }
    if ($m -match 'File path not found|Failed to read file')                      { return 'local' }
    return 'desconocido'
}

function Get-MotivoManual ($f) {
    switch ($f.Tipo) {
        'transitorio' { return 'error de red que siguio fallando en todas las rondas (puede ser pasajero: reintentar mas tarde)' }
        'hash'        { return 'hash invalido: lo que se descargo no coincide con el .pw.toml (el autor re-subio el archivo, o el .pw.toml quedo viejo)' }
        'http'        { return 'la descarga devolvio un error HTTP permanente (mod eliminado u oculto en CurseForge/Modrinth?)' }
        'local'       { return 'falta un archivo del propio repo (correr packwiz refresh?)' }
    }
    return 'motivo no reconocido'
}

# Separa "<nombre del mod>: <motivo>" y busca a que .pw.toml corresponde.
# El nombre puede tener ": " adentro ("Enhanced Celestials 2: Shader
# Support"), asi que se prueba cada corte hasta dar con un mod real.
function Resolve-Failure ($f, $metaList) {
    $cands = @()
    if ($f.Jar) {
        $key   = $f.Jar.ToLowerInvariant()
        $cands = @($metaList | Where-Object { $_.Jar -eq $key })
    }

    $cortes = @()
    $idx = $f.Texto.IndexOf(': ')
    while ($idx -ge 0) { $cortes += $idx; $idx = $f.Texto.IndexOf(': ', $idx + 2) }

    $nombre = $null
    $motivo = ''
    foreach ($c in $cortes) {
        $n = $f.Texto.Substring(0, $c)
        $k = Get-NameKey $n
        $porNombre = @($metaList | Where-Object { $k -ne '' -and $_.ClaveMod -eq $k })
        $porJar    = @($metaList | Where-Object { $_.Jar -eq $n.ToLowerInvariant() })
        if ($porNombre.Count -gt 0 -or $porJar.Count -gt 0 -or $n -like '*.jar') {
            $nombre = $n
            $motivo = $f.Texto.Substring($c + 2)
            if ($cands.Count -eq 0) { $cands = @($porNombre + $porJar) }
            break
        }
    }
    if ($null -eq $nombre) {
        if ($cortes.Count -gt 0) {
            $nombre = $f.Texto.Substring(0, $cortes[0])
            $motivo = $f.Texto.Substring($cortes[0] + 2)
        } else {
            $nombre = $f.Texto
        }
    }

    $jar = $f.Jar
    if (-not $jar) {
        if ($cands.Count -gt 0)      { $jar = $cands[0].Archivo }
        elseif ($nombre -like '*.jar') { $jar = $nombre }
    }

    $motivoCompleto = ("$motivo $($f.Extra)").Trim()
    return [pscustomobject]@{
        Nombre     = $nombre
        Motivo     = $motivoCompleto
        Jar        = $jar
        Candidatos = @($cands | Sort-Object Path -Unique)
        Linea      = $f.Linea
        Tipo       = (Get-FailureKind $motivoCompleto)
    }
}

function New-Pendiente ($f, [string] $motivo) {
    $etiqueta = $f.Nombre
    if ($f.Jar -and $f.Jar -ne $f.Nombre) { $etiqueta = "$($f.Nombre) ($($f.Jar))" }
    return [pscustomobject]@{ Jar = $etiqueta; Motivo = $motivo; Linea = $f.Linea }
}

# Mod bloqueado por el autor -> override. Devuelve $true si lo arreglo;
# si no, deja el motivo en $pendientes y no toca nada.
function Convert-ToOverride ($f, $pendientes) {
    if (-not $f.Jar) {
        $pendientes.Add((New-Pendiente $f 'bloqueado por el autor en CurseForge, pero no se pudo saber que .jar es'))
        Write-Warn "$($f.Nombre) : bloqueado, pero no se identifico el .jar. Revision manual."
        return $false
    }
    $jar = $f.Jar

    # De donde sacamos el .jar real: primero la instancia de CurseForge,
    # si no, el que ya pueda estar en mods\
    $origenJar  = Join-Path $SourceMods $jar
    $destinoJar = Join-Path $modsDir $jar
    $fuente = $null
    if (Test-Path -LiteralPath $origenJar)      { $fuente = $origenJar }
    elseif (Test-Path -LiteralPath $destinoJar) { $fuente = $destinoJar }

    if (-not $fuente) {
        $pendientes.Add((New-Pendiente $f 'bloqueado por el autor en CurseForge, y no se encontro el .jar ni en la instancia ni en mods\'))
        Write-Warn "$jar : no hay .jar disponible, requiere revision manual."
        return $false
    }

    $mb = [math]::Round((Get-Item -LiteralPath $fuente).Length / 1MB, 2)
    if ($mb -gt $MaxMB) {
        $pendientes.Add((New-Pendiente $f "bloqueado por el autor y es un archivo grande ($mb MB, limite $MaxMB MB): no se convirtio para no romper el limite de 100 MB de GitHub"))
        Write-Warn "$jar : $mb MB, supera $MaxMB MB. NO se convierte, requiere revision manual."
        return $false
    }

    # 1) dejar el .jar fisico en mods\
    if ($fuente -ne $destinoJar) {
        Copy-Item -LiteralPath $fuente -Destination $destinoJar -Force
    }
    # 2) borrar el/los .pw.toml para que pase a ser override
    $borrados = @()
    foreach ($c in $f.Candidatos) {
        $borrados += $c.Nombre
        Remove-Item -LiteralPath $c.Path -Force
    }

    if ($borrados.Count -eq 0) {
        $pendientes.Add((New-Pendiente $f 'no se encontro el .pw.toml correspondiente (se copio el .jar igual)'))
        Write-Warn "$jar : no se encontro su .pw.toml, revisar a mano."
        return $false
    }

    $metaBorrado = ($borrados -join ', ')
    $convertidos.Add([pscustomobject]@{ Jar = $jar; Meta = $metaBorrado; MB = $mb })
    Write-Step "$jar -> override (bloqueado por el autor en CurseForge; se borro $metaBorrado, $mb MB)"
    return $true
}

# ---------------------------------------------------------------------
#  Arranque
# ---------------------------------------------------------------------

$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$modsDir     = Join-Path $ProjectRoot 'mods'
$packToml    = Join-Path $ProjectRoot 'pack.toml'
$reporte     = Join-Path $ProjectRoot 'mods-fallidos.txt'
$bootstrap   = Join-Path $ProjectRoot 'packwiz-installer-bootstrap.jar'
$archivoReemplazos = Join-Path $ProjectRoot 'mods-reemplazos.txt'
$archivoConservar  = Join-Path $ProjectRoot 'mods-conservar.txt'

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
# packwiz refresh trabaja sobre el pack.toml de la carpeta actual
Set-Location -LiteralPath $ProjectRoot

$convertidos = New-Object System.Collections.Generic.List[object]   # bloqueados -> override
$duplicados  = New-Object System.Collections.Generic.List[object]   # duplicados conocidos borrados
$podados     = New-Object System.Collections.Generic.List[object]   # obsoletos borrados
$listados    = New-Object System.Collections.Generic.List[object]   # obsoletos detectados, NO borrados
$manuales    = New-Object System.Collections.Generic.List[object]   # revision manual (fuera de la instalacion)
$pendientes  = @()                                                   # fallos sin arreglar de la ultima ronda

# ---------------------------------------------------------------------
#  Fase 1: duplicados conocidos
# ---------------------------------------------------------------------

$metaList = @(Get-MetaList $modsDir)
foreach ($g in @($metaList | Group-Object Jar)) {
    $conUrl = @($g.Group | Where-Object { $_.TieneUrl -and -not $_.EsCF })
    $soloCF = @($g.Group | Where-Object { $_.EsCF })
    if ($conUrl.Count -eq 0 -or $soloCF.Count -eq 0) { continue }
    foreach ($dup in $soloCF) {
        Remove-Item -LiteralPath $dup.Path -Force
        $duplicados.Add([pscustomobject]@{ Jar = $dup.Archivo; Borrado = $dup.Nombre; Motivo = "ya lo cubre $($conUrl[0].Nombre) (descarga directa)" })
        Write-Step "$($dup.Archivo) -> duplicado conocido: se borro $($dup.Nombre) (ya lo cubre $($conUrl[0].Nombre))"
    }
}

$metaList = @(Get-MetaList $modsDir)
$declarados = @{}
foreach ($m in $metaList) { $declarados[$m.Jar] = $m.Nombre }
foreach ($j in @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File)) {
    $k = $j.Name.ToLowerInvariant()
    if (-not $declarados.ContainsKey($k)) { continue }
    Remove-Item -LiteralPath $j.FullName -Force
    $duplicados.Add([pscustomobject]@{ Jar = $j.Name; Borrado = "$($j.Name) (.jar suelto)"; Motivo = "ya lo declara $($declarados[$k])" })
    Write-Step "$($j.Name) -> duplicado conocido: se borro el .jar suelto (ya lo declara $($declarados[$k]))"
}

# ---------------------------------------------------------------------
#  Fase 2: poda de obsoletos (+ mods-reemplazos.txt)
# ---------------------------------------------------------------------

$script:srcJars = @(Get-ChildItem -LiteralPath $SourceMods -File -Filter '*.jar' -ErrorAction SilentlyContinue)
foreach ($j in $script:srcJars) { $script:srcByName[$j.Name.ToLowerInvariant()] = $j }

$conservar = @(Read-ListFile $archivoConservar | ForEach-Object { ($_ -replace '\.pw\.toml$', '').ToLowerInvariant() })

$reemplazos = New-Object System.Collections.Generic.List[object]
foreach ($l in @(Read-ListFile $archivoReemplazos)) {
    if ($l -match '^(\S+)\s*->\s*(\S+)$') {
        $reemplazos.Add([pscustomobject]@{ Viejo = ($Matches[1] -replace '\.pw\.toml$', ''); Nuevo = ($Matches[2] -replace '\.pw\.toml$', '') })
    } else {
        Write-Warn "mods-reemplazos.txt: se ignora una linea mal escrita (formato: viejo -> nuevo): $l"
    }
}

$metaList = @(Get-MetaList $modsDir)
$metaPorSlug = @{}
foreach ($m in $metaList) { $metaPorSlug[$m.Slug.ToLowerInvariant()] = $m }

if ($script:srcJars.Count -eq 0) {
    $manuales.Add([pscustomobject]@{ Jar = '(poda de obsoletos)'; Motivo = "la instancia de CurseForge no tiene ningun .jar ($SourceMods): no se analizo nada"; Linea = '' })
    Write-Fail "La instancia de CurseForge no tiene ningun .jar: no se analiza la poda."
} else {
    $obsoletos = New-Object System.Collections.Generic.List[object]
    foreach ($m in $metaList) {
        if ($conservar -contains $m.Slug.ToLowerInvariant()) { continue }
        if (Test-EnInstancia $m) { continue }
        $motivo = 'su .jar ya no esta en la instancia de CurseForge (ni por nombre ni por hash)'
        $r = @($reemplazos | Where-Object { $_.Viejo -eq $m.Slug }) | Select-Object -First 1
        if ($r) {
            $motivo = "reemplazado por $($r.Nuevo)"
            if (-not (Test-ReemplazoPresente $r.Nuevo $metaPorSlug)) { $motivo += ' (OJO: el reemplazo tampoco esta en la instancia)' }
        }
        $obsoletos.Add([pscustomobject]@{ Meta = $m; Motivo = $motivo })
    }

    # Viejo y nuevo instalados a la vez: no se borra nada del repo, porque
    # el server copia de la instancia y quedaria con los dos.
    foreach ($r in $reemplazos) {
        $viejo = $metaPorSlug[$r.Viejo.ToLowerInvariant()]
        if ($null -eq $viejo -or -not (Test-EnInstancia $viejo)) { continue }
        if (-not (Test-ReemplazoPresente $r.Nuevo $metaPorSlug))  { continue }
        $manuales.Add([pscustomobject]@{
            Jar    = "$($viejo.Nombre) ($($viejo.Archivo))"
            Motivo = "conflicto de reemplazo: $($r.Viejo) y su reemplazo $($r.Nuevo) estan LOS DOS en la instancia de CurseForge. Saca $($r.Viejo) de CurseForge (si no, el server tambien queda con los dos)."
            Linea  = ''
        })
        Write-Warn "$($r.Viejo) y su reemplazo $($r.Nuevo) estan los dos en la instancia. NO se borra nada."
    }

    if ($obsoletos.Count -gt 0) {
        $frenado = $obsoletos.Count -gt $MaxPrune
        if ($frenado -or $PruneMode -eq 'listar') {
            if ($frenado) {
                $porque = "poda frenada: $($obsoletos.Count) obsoletos supera el limite de $MaxPrune (revisa la ruta ORIGEN)"
                Write-Fail "Hay $($obsoletos.Count) .pw.toml obsoletos y el limite es $MaxPrune. NO se borra ninguno."
            } else {
                $porque = 'modo listar (PODA=listar en sync-modpack.bat)'
            }
            foreach ($o in $obsoletos) {
                $listados.Add([pscustomobject]@{ Toml = $o.Meta.Nombre; Jar = $o.Meta.Archivo; Motivo = $o.Motivo; Porque = $porque })
                Write-Warn "$($o.Meta.Nombre) : obsoleto ($($o.Motivo)). NO se borra: $porque."
            }
        } else {
            foreach ($o in $obsoletos) {
                Remove-Item -LiteralPath $o.Meta.Path -Force
                $podados.Add([pscustomobject]@{ Toml = $o.Meta.Nombre; Jar = $o.Meta.Archivo; Motivo = $o.Motivo })
                Write-Step "$($o.Meta.Nombre) -> obsoleto podado ($($o.Motivo))"
            }
        }
    }
}

if ($duplicados.Count -gt 0 -or $podados.Count -gt 0) { Invoke-PackwizRefresh }

# ---------------------------------------------------------------------
#  Fase 3: instalacion de prueba
# ---------------------------------------------------------------------

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

$verificada = $false
$limpio     = $false
$agotadas   = $false
$ultimoLog  = $null
$rondas     = 0

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
        if (Test-Path -LiteralPath $f) { $texto += (Get-Content -LiteralPath $f -Encoding UTF8) }
    }
    Set-Content -LiteralPath $ultimoLog -Value $texto -Encoding UTF8

    $verificada = $true   # la prueba REAL corrio (haya salido bien o mal)
    Write-Step ("Ronda {0} : el installer termino con codigo {1} en {2:N0}s" -f $ronda, $exit, $sw.Elapsed.TotalSeconds)

    if ($exit -eq 0) { $limpio = $true; $pendientes = @(); break }

    # Si no pudo leer ni el pack.toml / index.toml no hay nada por mod que arreglar
    $fatal = @($texto | Where-Object { $_ -match 'Failed to (download|parse|process) (pack\.toml|index file)|index file hash is invalid' })
    if ($fatal.Count -gt 0) {
        Write-Fail "El installer no pudo leer el pack: $($fatal[0].Trim())"
        Write-Fail "Log completo: $ultimoLog"
        exit 3
    }

    $metaList = @(Get-MetaList $modsDir)
    $fallos = New-Object System.Collections.Generic.List[object]
    $vistos = @{}
    foreach ($crudo in @(Get-InstallFailures $ultimoLog)) {
        $r = Resolve-Failure $crudo $metaList
        $clave = if ($r.Jar) { $r.Jar.ToLowerInvariant() } else { Get-NameKey $r.Nombre }
        if ($vistos.ContainsKey($clave)) { continue }
        $vistos[$clave] = $true
        $fallos.Add($r)
    }

    if ($fallos.Count -eq 0) {
        Write-Fail "El installer fallo (codigo $exit) pero no se pudo identificar ningun mod."
        Write-Fail "Esto NO es un 'todo OK': la verificacion no se pudo completar."
        Write-Fail "Log completo: $ultimoLog"
        exit 3
    }

    Write-Step "Ronda $ronda : $($fallos.Count) mod(s) no se pudieron descargar."

    $cambios      = 0
    $transitorios = 0
    $pendRonda    = New-Object System.Collections.Generic.List[object]

    foreach ($f in $fallos) {
        $candidatos = @($f.Candidatos)

        # Red de seguridad: un .jar no puede estar declarado por media
        # docena de .pw.toml. Si pasa, algo esta mal en el filtro y es
        # preferible frenar antes que borrar metadata de medio pack.
        if ($candidatos.Count -gt 3) {
            throw "Filtro roto: $($f.Nombre) coincidio con $($candidatos.Count) archivos .pw.toml. No se borra nada."
        }

        # --- Duplicado conocido -------------------------------------
        # El mismo .jar ya esta cubierto por otro .pw.toml que baja por
        # URL directa (tipicamente Modrinth): alcanza con borrar la copia
        # de CurseForge, que es la que falla.
        $conUrl = @($candidatos | Where-Object { $_.TieneUrl -and -not $_.EsCF })
        $soloCF = @($candidatos | Where-Object { $_.EsCF })
        if ($conUrl.Count -gt 0 -and $soloCF.Count -gt 0) {
            foreach ($dup in $soloCF) {
                Remove-Item -LiteralPath $dup.Path -Force
                $duplicados.Add([pscustomobject]@{ Jar = $dup.Archivo; Borrado = $dup.Nombre; Motivo = "ya lo cubre $($conUrl[0].Nombre) (descarga directa)" })
                Write-Step "$($dup.Archivo) -> duplicado conocido: se borro $($dup.Nombre) (ya lo cubre $($conUrl[0].Nombre))"
                $cambios++
            }
            continue
        }

        Write-Step "  $($f.Nombre) : [$($f.Tipo)] $($f.Motivo)"

        if ($f.Tipo -eq 'bloqueado') {
            if (Convert-ToOverride $f $pendRonda) { $cambios++ }
        } elseif ($f.Tipo -eq 'transitorio') {
            $transitorios++
            $pendRonda.Add((New-Pendiente $f (Get-MotivoManual $f)))
            if ($ronda -lt $MaxRounds) {
                Write-Warn "$($f.Nombre) : error de red. No se toca nada; se reintenta en la ronda siguiente."
            } else {
                Write-Warn "$($f.Nombre) : error de red y no quedan rondas. NO se toca su .pw.toml."
            }
        } else {
            $pendRonda.Add((New-Pendiente $f (Get-MotivoManual $f)))
            Write-Warn "$($f.Nombre) : $(Get-MotivoManual $f). NO se toca su .pw.toml."
        }
    }

    $pendientes = $pendRonda.ToArray()

    if ($cambios -gt 0) {
        Invoke-PackwizRefresh
        if ($ronda -eq $MaxRounds) { $agotadas = $true }
        continue
    }
    if ($transitorios -gt 0 -and $ronda -lt $MaxRounds) {
        Write-Step 'Solo quedan fallos que no se arreglan tocando el pack; como hay errores de red, se espera 30 s y se reintenta.'
        Start-Sleep -Seconds 30
        continue
    }
    Write-Fail 'Hay mods que fallan pero ninguno se puede arreglar automaticamente.'
    break
}

# ---------------------------------------------------------------------
#  Reporte y limpieza
# ---------------------------------------------------------------------

[void](Remove-DirHard $instance)

if (-not $verificada) {
    Write-Fail 'La verificacion no llego a ejecutarse.'
    exit 2
}

if ($agotadas) {
    $manuales.Add([pscustomobject]@{ Jar = '(verificacion)'; Motivo = "se agotaron las $MaxRounds rondas: los arreglos de la ultima ronda no se llegaron a probar. Volve a correr sync-modpack.bat."; Linea = '' })
}

$manualesTodos = @($manuales.ToArray()) + @($pendientes)
$total = $convertidos.Count + $duplicados.Count + $podados.Count + $listados.Count + $manualesTodos.Count

if ($total -eq 0) {
    if ($limpio) {
        Write-Host ''
        Write-Host "  VERIFICACION REAL COMPLETADA ($rondas ronda(s)): el installer instalo" -ForegroundColor Green
        Write-Host '  el pack entero sin un solo error. Todos los mods son descargables.' -ForegroundColor Green
    } else {
        Write-Fail 'La verificacion termino sin poder confirmar que el pack este sano.'
        Write-Fail "Log: $ultimoLog"
        exit 3
    }
    # si no hay nada que contar no se deja ningun archivo suelto
    if (Test-Path -LiteralPath $reporte) { Remove-Item -LiteralPath $reporte -Force }
    exit 0
}

# --- Hubo cambios o pendientes: escribir el reporte ---
$r = New-Object System.Collections.Generic.List[string]
$r.Add('============================================================')
$r.Add(' Reporte de verificacion de descarga - modpack Guild 2.0')
$r.Add(" Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$r.Add(" Rondas de verificacion: $rondas")
$r.Add(" Poda de obsoletos: $PruneMode")
$r.Add('============================================================')
$r.Add('')

if ($podados.Count -gt 0) {
    $r.Add("OBSOLETOS PODADOS ($($podados.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add('Su .jar ya no esta en la instancia de CurseForge: se borro el')
    $r.Add('.pw.toml. A los jugadores se les borra el .jar solo en el proximo')
    $r.Add('arranque (packwiz-installer borra lo que el mismo instalo y salio')
    $r.Add('del pack).')
    $r.Add('')
    foreach ($p in $podados) {
        $r.Add("  * $($p.Toml)  ($($p.Jar))")
        $r.Add("      motivo : $($p.Motivo)")
    }
    $r.Add('')
}

if ($listados.Count -gt 0) {
    $r.Add("OBSOLETOS DETECTADOS - NO SE BORRO NADA ($($listados.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add('Su .jar ya no esta en la instancia de CurseForge, pero siguen en')
    $r.Add('el pack: los jugadores los siguen bajando y el server no los tiene.')
    $r.Add("Por que no se borraron: $($listados[0].Porque)")
    $r.Add('Si la lista esta bien, pone PODA=borrar en sync-modpack.bat y se')
    $r.Add('van a borrar solos. Si alguno tiene que quedarse, anotalo en')
    $r.Add('mods-conservar.txt.')
    $r.Add('')
    foreach ($p in $listados) {
        $r.Add("  * $($p.Toml)  ($($p.Jar))")
        $r.Add("      motivo : $($p.Motivo)")
    }
    $r.Add('')
}

if ($duplicados.Count -gt 0) {
    $r.Add("DUPLICADOS CONOCIDOS BORRADOS ($($duplicados.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add('El mismo .jar estaba declarado dos veces. No se pierde ningun mod:')
    $r.Add('lo sigue cubriendo el otro.')
    $r.Add('')
    foreach ($d in $duplicados) {
        $r.Add("  * $($d.Jar)")
        $r.Add("      borrado : $($d.Borrado)")
        $r.Add("      motivo  : $($d.Motivo)")
    }
    $r.Add('')
}

if ($convertidos.Count -gt 0) {
    $r.Add("CONVERTIDOS A OVERRIDE ($($convertidos.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add('El autor excluyo estos mods de la API de CurseForge. Se borro su')
    $r.Add('.pw.toml y el .jar real quedo dentro de mods\, asi se distribuye')
    $r.Add('como archivo directo y no depende de ninguna API externa.')
    $r.Add('')
    foreach ($c in $convertidos) {
        $r.Add("  * $($c.Jar)")
        $r.Add("      .pw.toml borrado : $($c.Meta)")
        $r.Add("      tamano           : $($c.MB) MB")
    }
    $r.Add('')
}

if ($manualesTodos.Count -gt 0) {
    $r.Add("REQUIERE REVISION MANUAL - NO SE TOCO NADA ($($manualesTodos.Count))")
    $r.Add('------------------------------------------------------------')
    foreach ($m in $manualesTodos) {
        $r.Add("  * $($m.Jar)")
        $r.Add("      motivo : $($m.Motivo)")
        if ($m.Linea) { $r.Add("      log    : $($m.Linea)") }
    }
    $r.Add('')
    if (@($manualesTodos | Where-Object { $_.Motivo -match 'archivo grande' }).Count -gt 0) {
        $r.Add('Para los archivos grandes: subilos a Modrinth/otro host y agregalos')
        $r.Add('con "packwiz url add", o usa Git LFS. NO los subas tal cual: GitHub')
        $r.Add('rechaza archivos de mas de 100 MB.')
        $r.Add('')
    }
}

if ($limpio) {
    $r.Add('RESULTADO DE LA INSTALACION DE PRUEBA: OK')
    $r.Add('Despues de los arreglos, la instalacion de prueba termino sin errores.')
} else {
    $r.Add('RESULTADO DE LA INSTALACION DE PRUEBA: CON PENDIENTES')
    $r.Add('La instalacion de prueba TODAVIA falla. Revisa los casos manuales.')
}
$r.Add('')
$r.Add("Log completo del installer: $ultimoLog")
$r.Add('')
$r.Add('NOTA: "packwiz curseforge detect" (paso 6) vuelve a convertir los')
$r.Add('overrides en metadata de CurseForge en cada sincronizacion. Por eso')
$r.Add('el paso 7 los vuelve a pasar a override automaticamente cada vez. Es')
$r.Add('esperado: no hace falta que hagas nada a mano.')

Set-Content -LiteralPath $reporte -Value $r -Encoding UTF8

Write-Host ''
Write-Host '  RESUMEN'
Write-Host ("    Obsoletos podados              : {0}" -f $podados.Count)
Write-Host ("    Obsoletos detectados (sin borrar): {0}" -f $listados.Count)
Write-Host ("    Duplicados conocidos borrados  : {0}" -f $duplicados.Count)
Write-Host ("    Convertidos a override         : {0}" -f $convertidos.Count)
Write-Host ("    Revision manual (sin tocar)    : {0}" -f $manualesTodos.Count)
Write-Host ''
if ($limpio) {
    Write-Host "  VERIFICACION REAL COMPLETADA ($rondas ronda(s)): la instalacion de prueba" -ForegroundColor Green
    Write-Host '  final termino sin errores.' -ForegroundColor Green
} else {
    Write-Warn 'La instalacion de prueba todavia falla. Revisa el reporte.'
}
if ($listados.Count -gt 0 -or $manualesTodos.Count -gt 0) {
    Write-Warn 'Hay cosas para revisar a mano antes de hacer push.'
}
Write-Host "  Detalle en: $reporte"

if ($limpio -and $listados.Count -eq 0 -and $manualesTodos.Count -eq 0) { exit 0 } else { exit 1 }
