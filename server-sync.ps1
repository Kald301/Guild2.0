# =========================================================
#  server-sync.ps1  --  motor de server-sync.bat
#
#  Espeja hacia el servidor:
#    - los .jar de la instancia, salteando los de la blacklist
#    - la carpeta config entera (la blacklist NO aplica a config)
#
#  NO se edita nada aca: las rutas se configuran en server-sync.bat.
#  Este script no toca git, no corre packwiz y no toca ninguna
#  carpeta fuera de -Dest y -DestConfig.
#
#  Codigos de salida:
#    0 = todo ok
#    1 = ok, pero hay avisos (blacklist desactualizada / duplicados)
#    2 = error de validacion (no se toco NADA en el destino)
#    3 = error durante la copia (se revirtio, el destino quedo como estaba)
#    4 = error inesperado
# =========================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Source,
    [Parameter(Mandatory = $true)] [string] $Dest,
    [Parameter(Mandatory = $true)] [string] $Blacklist,
    [string] $SourceConfig = '',
    [string] $DestConfig   = '',
    [string] $KeepConfig   = '',    # separadas por coma; llega como texto desde el .bat
    [switch] $ListOnly
)

# Lo que el server genera por su cuenta y no hay que borrar al espejar config
$keepList = @($KeepConfig -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$ErrorActionPreference = 'Stop'

$TMP_EXT = '.tmpsync'
$BAK_EXT = '.baksync'

# ---------------------------------------------------------
#  NORMALIZACION DE NOMBRES (solo para mods)
#
#  Un token se considera "de version" si es un numero de version,
#  un loader, un marcador de MC o ruido tipico de release.
#  El nombre base de un .jar es lo que queda al tirar, de derecha a
#  izquierda, todos los tokens de version hasta el primero que no lo sea.
# ---------------------------------------------------------

$RE_VERSION = '^[vr]?\d[\w.]*$'                                            # 1.6.0  v6.3.8  2101.1.0  1.1.24a
$RE_MCVER   = '^mc[\d.]+\w*$'                                              # mc1.21.1  mc1.21
$RE_LOADER  = '^\[?(neo|neoforge|neoforged|forge|fabric|quilt)\]?[\d.]*$'  # neoforge  [Neoforge]  neoforged.1.21.1
$RE_NOISE   = '^(build|bugfix|hotfix|beta|alpha|rc|pre|snapshot|release|universal|all|mc|v)[\d.]*$'

function Test-VersionToken {
    param([string] $Token)
    if ([string]::IsNullOrEmpty($Token)) { return $true }   # separadores dobles: "NeoForge--1.0.0"
    return ($Token -match $RE_VERSION) -or ($Token -match $RE_MCVER) -or
           ($Token -match $RE_LOADER)  -or ($Token -match $RE_NOISE)
}

# Nombre base sugerido de un archivo (lo que imprime --list).
function Get-ModBaseName {
    param([string] $FileName)
    $name  = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $parts = [regex]::Split($name, '[-_+]')
    $seps  = @([regex]::Matches($name, '[-_+]') | ForEach-Object { $_.Value })

    $i = $parts.Count - 1
    while ($i -ge 1 -and (Test-VersionToken $parts[$i])) { $i-- }   # el token 0 nunca se tira

    $out = $parts[0]
    for ($k = 1; $k -le $i; $k++) { $out += $seps[$k - 1] + $parts[$k] }

    # cola con separador "." (ej: inventoryhud.neoforged.1.21.1)
    while ($out -match '^(.+)\.([^.]+)$' -and (Test-VersionToken $Matches[2]) -and $Matches[1] -ne '') {
        $out = $Matches[1]
    }
    return $out
}

# Decide si un .jar cae bajo una entrada de la blacklist.
#   - entrada con * -> patron contra el nombre de archivo completo
#   - si no         -> el archivo tiene que empezar con la entrada y lo
#                      que sobra tiene que ser SOLO tokens de version
function Test-MatchesEntry {
    param([string] $FileName, [string] $Entry)

    if ($Entry -match '\*') {
        return ($FileName -like $Entry) -or ($FileName -like "$Entry.jar")
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($name.Length -lt $Entry.Length) { return $false }
    if ($name.Substring(0, $Entry.Length) -ne $Entry) { return $false }     # -ne de string es case-insensitive

    $rest = $name.Substring($Entry.Length)
    if ($rest -eq '') { return $true }                                      # nombre exacto completo
    if ($rest[0] -notmatch '[-_+.]') { return $false }                      # "create" vs "createaddition"

    foreach ($tok in [regex]::Split($rest.Substring(1), '[-_+]')) {
        if (-not (Test-VersionToken $tok)) { return $false }                # "create" vs "create-gunsmithing"
    }
    return $true
}

function Read-Blacklist {
    param([string] $Path)
    $entries = @()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $t = ($t -split '\s+#')[0].Trim()                   # comentario al final de la linea
        if ($t -eq '') { continue }
        if ($t.ToLower().EndsWith('.jar') -and $t -notmatch '\*') {
            $t = $t.Substring(0, $t.Length - 4)             # el .jar sobra, se ignora
        }
        if ($entries -notcontains $t) { $entries += $t }
    }
    return $entries
}

function Get-Jars {
    param([string] $Path)
    return @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -eq '.jar' })
}

# Ruta relativa a una carpeta raiz, siempre con "\"
function Get-RelPath {
    param([string] $Root, [string] $Full)
    return $Full.Substring($Root.Length).TrimStart('\', '/')
}

# Archivos de config que genera el propio servidor y NO hay que borrar.
# Cada entrada es un prefijo de ruta relativa, o un patron con *.
function Test-KeepConfig {
    param([string] $RelPath, [string[]] $Patterns)
    foreach ($p in $Patterns) {
        if ($p -eq '') { continue }
        if ($p -match '\*') {
            if ($RelPath -like $p) { return $true }
        } else {
            $norm = $p.Replace('/', '\').Trim('\')
            if ($RelPath -eq $norm -or $RelPath.StartsWith($norm + '\')) { return $true }
        }
    }
    return $false
}

# Dos archivos son "iguales" si coinciden tamano y fecha (criterio de robocopy)
function Test-SameFile {
    param($A, $B)
    if ($A.Length -ne $B.Length) { return $false }
    return ([math]::Abs(($A.LastWriteTimeUtc - $B.LastWriteTimeUtc).TotalSeconds) -le 2)
}

try {

# =========================================================
#  1. VALIDACION  (antes de tocar absolutamente nada)
# =========================================================

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Host "[ERROR] No existe la carpeta de mods de origen:" -ForegroundColor Red
    Write-Host "  $Source"
    exit 2
}
if (-not (Test-Path -LiteralPath $Blacklist -PathType Leaf)) {
    Write-Host "[ERROR] No existe el archivo de blacklist:" -ForegroundColor Red
    Write-Host "  $Blacklist"
    exit 2
}

$sourceJars = Get-Jars $Source
if ($sourceJars.Count -eq 0) {
    Write-Host "[ERROR] No hay ningun .jar en el origen. Se aborta por las dudas" -ForegroundColor Red
    Write-Host "        (espejar una carpeta vacia borraria todos los mods del server)."
    exit 2
}

$entries = Read-Blacklist $Blacklist

# ---- Modo listado: no toca el destino ----
if ($ListOnly) {
    Write-Host ""
    Write-Host "Mods en el origen y su entrada sugerida para la blacklist:"
    Write-Host ""
    Write-Host ("  {0,-42} {1}" -f 'ENTRADA SUGERIDA', 'ARCHIVO')
    Write-Host ("  {0,-42} {1}" -f ('-' * 42), ('-' * 50))
    foreach ($j in ($sourceJars | Sort-Object Name)) {
        Write-Host ("  {0,-42} {1}" -f (Get-ModBaseName $j.Name), $j.Name)
    }
    Write-Host ""
    Write-Host "Total: $($sourceJars.Count) mods. No se copio ni borro nada."
    Write-Host "(La blacklist no aplica a config: config se espeja entera.)"
    exit 0
}

if (-not (Test-Path -LiteralPath $Dest -PathType Container)) {
    Write-Host "[ERROR] No existe la carpeta de mods del servidor:" -ForegroundColor Red
    Write-Host "  $Dest"
    Write-Host "Revisa la ruta DESTINO al inicio de server-sync.bat."
    exit 2
}

# config es opcional: si no se configuro, se saltea
$doConfig = ($SourceConfig -ne '' -and $DestConfig -ne '')
if ($doConfig) {
    if (-not (Test-Path -LiteralPath $SourceConfig -PathType Container)) {
        Write-Host "[ERROR] No existe la carpeta config de origen:" -ForegroundColor Red
        Write-Host "  $SourceConfig"
        Write-Host "Revisa CONFIG_ORIGEN al inicio de server-sync.bat."
        exit 2
    }
    if (-not (Test-Path -LiteralPath $DestConfig -PathType Container)) {
        Write-Host "[ERROR] No existe la carpeta config del servidor:" -ForegroundColor Red
        Write-Host "  $DestConfig"
        Write-Host "Revisa CONFIG_DESTINO al inicio de server-sync.bat."
        exit 2
    }
    # Misma red de seguridad que con los mods
    if (@(Get-ChildItem -LiteralPath $SourceConfig -File -Recurse).Count -eq 0) {
        Write-Host "[ERROR] La carpeta config de origen esta vacia. Se aborta por las dudas" -ForegroundColor Red
        Write-Host "        (espejarla borraria toda la config del server)."
        exit 2
    }
}

# =========================================================
#  2. MODS: CLASIFICACION  (todo en memoria, sin escribir)
# =========================================================

$allowed  = @()
$excluded = @()
$hitCount = @{}
foreach ($e in $entries) { $hitCount[$e] = 0 }

foreach ($jar in $sourceJars) {
    $hit = $null
    foreach ($e in $entries) {
        if (Test-MatchesEntry $jar.Name $e) { $hit = $e; break }
    }
    if ($null -ne $hit) {
        $hitCount[$hit]++
        $excluded += [pscustomobject]@{ File = $jar.Name; Entry = $hit }
    } else {
        $allowed += $jar
    }
}

$orphanEntries = @($entries | Where-Object { $hitCount[$_] -eq 0 })

# Dos archivos distintos del mismo mod en el origen: rompe el arranque del server.
$dupes = @($allowed | Group-Object { (Get-ModBaseName $_.Name).ToLower() } | Where-Object { $_.Count -gt 1 })

# =========================================================
#  3. PLAN DE ESPEJO (mods + config), sin escribir todavia
# =========================================================

# ---- mods ----
$destJars   = Get-Jars $Dest
$destByName = @{}
foreach ($d in $destJars) { $destByName[$d.Name.ToLower()] = $d }

$allowedNames = @{}
foreach ($a in $allowed) { $allowedNames[$a.Name.ToLower()] = $true }

$modPlan = @()
foreach ($jar in $allowed) {
    $d = $destByName[$jar.Name.ToLower()]
    if (($null -eq $d) -or ($d.Length -ne $jar.Length)) {
        $modPlan += [pscustomobject]@{
            From  = $jar.FullName
            Final = (Join-Path $Dest $jar.Name)
            Name  = $jar.Name
            Size  = $jar.Length
        }
    }
}
$modDelete = @($destJars | Where-Object { -not $allowedNames.ContainsKey($_.Name.ToLower()) })

# ---- config (la blacklist NO aplica aca: se espeja entera) ----
$cfgPlan = @(); $cfgDelete = @(); $cfgSrcCount = 0
if ($doConfig) {
    $srcRoot = (Get-Item -LiteralPath $SourceConfig).FullName.TrimEnd('\')
    $dstRoot = (Get-Item -LiteralPath $DestConfig).FullName.TrimEnd('\')

    $srcFiles = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse)
    $cfgSrcCount = $srcFiles.Count

    $dstFiles = @(Get-ChildItem -LiteralPath $dstRoot -File -Recurse |
                  Where-Object { -not ($_.Name.EndsWith($TMP_EXT) -or $_.Name.EndsWith($BAK_EXT)) })
    $dstByRel = @{}
    foreach ($f in $dstFiles) { $dstByRel[(Get-RelPath $dstRoot $f.FullName).ToLower()] = $f }

    $srcRels = @{}
    foreach ($f in $srcFiles) {
        $rel = Get-RelPath $srcRoot $f.FullName
        $srcRels[$rel.ToLower()] = $true
        $d = $dstByRel[$rel.ToLower()]
        if (($null -eq $d) -or (-not (Test-SameFile $f $d))) {
            $cfgPlan += [pscustomobject]@{
                From  = $f.FullName
                Final = (Join-Path $dstRoot $rel)
                Name  = $rel
                Size  = $f.Length
            }
        }
    }

    foreach ($f in $dstFiles) {
        $rel = Get-RelPath $dstRoot $f.FullName
        if ($srcRels.ContainsKey($rel.ToLower())) { continue }
        if (Test-KeepConfig $rel $keepList)      { continue }   # lo genera el server
        $cfgDelete += $f
    }
}

# Restos de una corrida anterior que se haya cortado
$stale = @(Get-ChildItem -LiteralPath $Dest -File | Where-Object { $_.Name.EndsWith($TMP_EXT) -or $_.Name.EndsWith($BAK_EXT) })
if ($doConfig) {
    $stale += @(Get-ChildItem -LiteralPath $DestConfig -File -Recurse | Where-Object { $_.Name.EndsWith($TMP_EXT) -or $_.Name.EndsWith($BAK_EXT) })
}
foreach ($f in $stale) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }

# Espacio libre antes de empezar
$needed = 0
foreach ($p in @($modPlan + $cfgPlan)) { $needed += $p.Size }
$drive = (Get-Item -LiteralPath $Dest).PSDrive
if ($null -ne $drive -and $null -ne $drive.Free -and $drive.Free -lt ($needed + 50MB)) {
    Write-Host "[ERROR] Espacio insuficiente en $($drive.Name): hacen falta $([math]::Round($needed/1MB)) MB." -ForegroundColor Red
    Write-Host "        No se copio nada."
    exit 2
}

# =========================================================
#  4. COPIA EN DOS FASES (para no dejar el destino a medias)
#
#  Fase A: TODO (mods y config) se copia primero a un .tmpsync.
#          Si algo falla aca, se borran los temporales y ni el server
#          ni su config se tocaron.
#  Fase B: se renombran los .tmpsync al nombre final, guardando el
#          archivo viejo como .baksync. Si algo falla, se restauran.
#  Recien con todo aplicado se borra lo que sobra.
# =========================================================

$plan = @($modPlan + $cfgPlan)
Write-Host ""
Write-Host "Copiando $($modPlan.Count) mods y $($cfgPlan.Count) archivos de config..."

# --- Fase A ---
$staged   = @()   # From / Tmp / Final / Name
$newDirs  = @()   # carpetas creadas por nosotros (para revertir)
$failFile = ''
try {
    foreach ($p in $plan) {
        $dir = Split-Path -Parent $p.Final
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $newDirs += $dir
        }
        $failFile = $p.Name
        $tmp = $p.Final + $TMP_EXT
        Copy-Item -LiteralPath $p.From -Destination $tmp -Force
        $staged += [pscustomobject]@{ Tmp = $tmp; Final = $p.Final; Name = $p.Name }
    }
}
catch {
    Write-Host ""
    Write-Host "[ERROR] Fallo al copiar '$failFile': $($_.Exception.Message)" -ForegroundColor Red
    foreach ($s in $staged) { Remove-Item -LiteralPath $s.Tmp -Force -ErrorAction SilentlyContinue }
    foreach ($d in ($newDirs | Sort-Object Length -Descending)) {
        if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) {
            Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "        Se descartaron los temporales. El destino quedo intacto." -ForegroundColor Red
    exit 3
}

# --- Fase B ---
$committed = @()   # Final / Bak
try {
    foreach ($s in $staged) {
        $bak = $null
        if (Test-Path -LiteralPath $s.Final) {
            $bak = $s.Final + $BAK_EXT
            Move-Item -LiteralPath $s.Final -Destination $bak -Force
        }
        Move-Item -LiteralPath $s.Tmp -Destination $s.Final -Force
        $committed += [pscustomobject]@{ Final = $s.Final; Bak = $bak }
    }
}
catch {
    Write-Host ""
    Write-Host "[ERROR] Fallo al aplicar la copia: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        Revirtiendo..." -ForegroundColor Red
    foreach ($c in $committed) {
        Remove-Item -LiteralPath $c.Final -Force -ErrorAction SilentlyContinue
        if ($null -ne $c.Bak) { Move-Item -LiteralPath $c.Bak -Destination $c.Final -Force -ErrorAction SilentlyContinue }
    }
    foreach ($s in $staged) { Remove-Item -LiteralPath $s.Tmp -Force -ErrorAction SilentlyContinue }
    foreach ($d in ($newDirs | Sort-Object Length -Descending)) {
        if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) {
            Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "        El destino quedo como estaba antes de correr el script." -ForegroundColor Red
    exit 3
}

foreach ($c in $committed) {
    if ($null -ne $c.Bak) { Remove-Item -LiteralPath $c.Bak -Force -ErrorAction SilentlyContinue }
}

$cfgCopied = @($committed | Where-Object { $_.Final.StartsWith($DestConfig, 'OrdinalIgnoreCase') }).Count
$modCopied = $committed.Count - $cfgCopied

# --- Borrado de lo que ya no corresponde (recien con todo aplicado) ---
$deleted = @()
foreach ($d in $modDelete) {
    Remove-Item -LiteralPath $d.FullName -Force
    $deleted += $d.Name
}
$cfgDeleted = @()
foreach ($f in $cfgDelete) {
    Remove-Item -LiteralPath $f.FullName -Force
    $cfgDeleted += (Get-RelPath $DestConfig $f.FullName)
}
# carpetas que quedaron vacias en config
if ($doConfig) {
    foreach ($d in (Get-ChildItem -LiteralPath $DestConfig -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending)) {
        if (@(Get-ChildItem -LiteralPath $d.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# =========================================================
#  5. RESUMEN
# =========================================================

# Por que se borro cada mod: se pasa el archivo del DESTINO por la blacklist,
# asi una version vieja que ya no esta en el origen igual se reporta bien.
function Test-Blacklisted {
    param([string] $FileName)
    foreach ($e in $entries) { if (Test-MatchesEntry $FileName $e) { return $true } }
    return $false
}
$delBlacklist = @($deleted | Where-Object { Test-Blacklisted $_ })
$delGone      = @($deleted | Where-Object { -not (Test-Blacklisted $_) })

Write-Host ""
Write-Host "============================================"
Write-Host " RESUMEN"
Write-Host "============================================"
Write-Host " MODS"
Write-Host ("   Mods en el origen        : {0}" -f $sourceJars.Count)
Write-Host ("   Copiados/actualizados    : {0}" -f $modCopied)
Write-Host ("   Ya estaban al dia        : {0}" -f ($allowed.Count - $modCopied))
Write-Host ("   Total en el server       : {0}" -f $allowed.Count)
Write-Host ("   Excluidos por blacklist  : {0}" -f $excluded.Count)

if ($excluded.Count -gt 0) {
    Write-Host ""
    Write-Host "   --- Excluidos por blacklist ---"
    foreach ($x in ($excluded | Sort-Object File)) {
        Write-Host ("     {0}" -f $x.File) -ForegroundColor DarkYellow
        Write-Host ("         (entrada: {0})" -f $x.Entry) -ForegroundColor DarkGray
    }
}

if ($deleted.Count -gt 0) {
    Write-Host ""
    Write-Host "   --- Mods borrados del server ---"
    foreach ($n in ($delBlacklist | Sort-Object)) { Write-Host ("     {0}   (paso a la blacklist)" -f $n) -ForegroundColor DarkYellow }
    foreach ($n in ($delGone      | Sort-Object)) { Write-Host ("     {0}   (ya no esta en el origen)" -f $n) -ForegroundColor DarkYellow }
}

Write-Host ""
if ($doConfig) {
    Write-Host " CONFIG  (la blacklist no aplica: se espeja entera)"
    Write-Host ("   Archivos en el origen    : {0}" -f $cfgSrcCount)
    Write-Host ("   Copiados/actualizados    : {0}" -f $cfgCopied)
    Write-Host ("   Ya estaban al dia        : {0}" -f ($cfgSrcCount - $cfgCopied))
    Write-Host ("   Borrados del server      : {0}" -f $cfgDeleted.Count)
    if ($cfgDeleted.Count -gt 0) {
        Write-Host ""
        Write-Host "   --- Config borrada del server (no esta en tu instancia) ---"
        foreach ($n in ($cfgDeleted | Sort-Object | Select-Object -First 25)) {
            Write-Host ("     {0}" -f $n) -ForegroundColor DarkYellow
        }
        if ($cfgDeleted.Count -gt 25) {
            Write-Host ("     ... y {0} mas" -f ($cfgDeleted.Count - 25)) -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Host " CONFIG  : desactivado (CONFIG_ORIGEN vacio en server-sync.bat)"
}

$warn = $false

if ($orphanEntries.Count -gt 0) {
    $warn = $true
    Write-Host ""
    Write-Host "  [AVISO] Entradas de la blacklist que no matchearon ningun mod:" -ForegroundColor Yellow
    foreach ($e in $orphanEntries) { Write-Host ("    {0}" -f $e) -ForegroundColor Yellow }
    Write-Host "  Puede ser un nombre mal escrito o un mod que ya no tenes instalado." -ForegroundColor Yellow
    Write-Host "  Corre 'server-sync.bat --list' para ver como se escribe cada mod." -ForegroundColor Yellow
}

if ($dupes.Count -gt 0) {
    $warn = $true
    Write-Host ""
    Write-Host "  [AVISO] Hay dos archivos del mismo mod en el origen (suele tirar el server):" -ForegroundColor Yellow
    foreach ($g in $dupes) {
        Write-Host ("    {0}:" -f $g.Name) -ForegroundColor Yellow
        foreach ($f in $g.Group) { Write-Host ("        {0}" -f $f.Name) -ForegroundColor Yellow }
    }
    Write-Host "  Borra la version vieja en tu instancia, o bloquea el archivo puntual." -ForegroundColor Yellow
}

Write-Host ""
if ($warn) { exit 1 } else { exit 0 }

}
catch {
    Write-Host ""
    Write-Host "[ERROR] Error inesperado: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 4
}
