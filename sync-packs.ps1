# =====================================================================
#  sync-packs.ps1  --  Paso 4 de sync-modpack.bat
#
#  Reemplaza al "robocopy /MIR" de resourcepacks\ y shaderpacks\, que
#  subia al repo (que es PUBLICO) los zips de terceros tal cual. Eso es
#  redistribuirlos y lo prohiben sus licencias: Complementary (1.2.d,
#  "no direct file upload"), Fresh Animations y Recolourful (ARR).
#
#  Cada cosa que hay en esas carpetas de la instancia de CurseForge cae
#  en UNO de estos casos, en este orden:
#
#  1. GENERADO EN CADA CLIENTE (packs-ignorar.txt)
#     Lo crean mods al arrancar: Euphoria Patcher ("<shader> + Euphoria
#     Patches_x"), IrisCaves ("<pack>_iriscaves"). No se sube: son
#     versiones modificadas de Complementary y cada cliente las regenera.
#  2. YA DECLARADO por un .pw.toml del repo con el mismo nombre de
#     archivo y el mismo hash (por ejemplo uno agregado a mano con
#     "packwiz curseforge add") -> se deja como esta.
#  3. EN MODRINTH (se busca el archivo por su SHA-1)
#     -> se escribe <carpeta>\<slug>.pw.toml apuntando a ESE archivo
#        exacto. Los jugadores lo bajan de Modrinth, como un mod.
#  4. PROPIO (packs-propios.txt) -> se copia tal cual al repo.
#  5. Cualquier otra cosa NO se publica y queda en packs-fallidos.txt
#     para revision manual. Un pack de terceros nunca se sube "por las
#     dudas".
#
#  Despues limpia el repo: borra lo suelto que no es propio (zips de
#  terceros, carpetas generadas) y poda los .pw.toml de packs que ya no
#  estan en la instancia, con el mismo freno MaxPrune que los mods.
#
#  Por ultimo deja en %LOCALAPPDATA%\packwiz-verify\packs-esperados.json
#  que archivos tiene que bajar un jugador (con su SHA-1) y cuales NO,
#  para que verify-mods.ps1 lo compruebe en la instalacion de prueba.
#
#  Codigos de salida:
#    0 = todo publicado como corresponde
#    1 = corrio, pero hay casos para revisar (packs-fallidos.txt)
#    2 = no se pudo consultar Modrinth: NO se toco nada del repo
#    4 = error inesperado
#
#  NO se invoca a mano: lo llama sync-modpack.bat.
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Origen,
    [Parameter(Mandatory = $true)][string] $Destino,
    [string[]] $Carpetas    = @('resourcepacks', 'shaderpacks'),
    [string]   $PruneMode   = 'borrar',
    [int]      $MaxPrune    = 10,
    [string]   $ModrinthApi = 'https://api.modrinth.com/v2',
    [string]   $Esperados   = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Mismo criterio que verify-mods.ps1: un error inesperado sale con 4,
# nunca con 1 (que el .bat leeria como "corrio con pendientes").
trap {
    Write-Host ''
    Write-Host '  [ERROR] La sincronizacion de packs se corto por un error inesperado:' -ForegroundColor Red
    Write-Host "          $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host "          (sync-packs.ps1 linea $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
    }
    exit 4
}

if ($PruneMode -ne 'listar' -and $PruneMode -ne 'borrar') {
    throw "PruneMode invalido: '$PruneMode' (tiene que ser 'listar' o 'borrar'). Revisa PODA en sync-modpack.bat."
}
if ($Esperados -eq '') { $Esperados = Join-Path $env:LOCALAPPDATA 'packwiz-verify\packs-esperados.json' }

# PowerShell 5.1 no siempre ofrece TLS 1.2 por defecto
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------
#  Utilidades
# ---------------------------------------------------------------------

function Write-Step ([string] $m) { Write-Host "  $m" }
function Write-Warn ([string] $m) { Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Write-Fail ([string] $m) { Write-Host "  [ERROR] $m" -ForegroundColor Red }

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

# Un patron de packs-propios.txt / packs-ignorar.txt es una ruta relativa
# al repo con comodines (resourcepacks/*.zip). Si termina en "/" solo
# coincide con carpetas; si no, solo con archivos.
function Test-Patron ([string] $rel, [bool] $esDir, [string[]] $patrones) {
    foreach ($p in $patrones) {
        $soloDir = $p.EndsWith('/')
        if ($soloDir -ne $esDir) { continue }
        $w = [System.Management.Automation.WildcardPattern]::new($p.TrimEnd('/'), [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($w.IsMatch($rel)) { return $true }
    }
    return $false
}

function Get-Sha ([string] $path, [string] $formato) {
    $alg = switch ($formato.ToLowerInvariant()) {
        'sha1'   { 'SHA1' }
        'sha256' { 'SHA256' }
        'sha512' { 'SHA512' }
        'md5'    { 'MD5' }
        default  { $null }
    }
    if ($null -eq $alg) { return $null }
    return (Get-FileHash -LiteralPath $path -Algorithm $alg).Hash.ToLowerInvariant()
}

function ConvertTo-TomlString ([string] $s) {
    return '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"'
}

# Lo minimo de un .pw.toml: nombre del archivo, hash y de donde baja
function Read-Meta ([string] $path) {
    $m = [ordered]@{ Path = $path; Nombre = [System.IO.Path]::GetFileName($path); Filename = ''; HashFormat = ''; Hash = ''; Url = ''; ModrinthVersion = '' }
    $seccion = ''
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $seccion = $Matches[1]; continue }
        if ($t -notmatch '^([A-Za-z0-9_-]+)\s*=\s*"((?:[^"\\]|\\.)*)"$') { continue }
        $clave = $Matches[1]
        $valor = $Matches[2] -replace '\\"', '"' -replace '\\\\', '\'
        if ($seccion -eq '' -and $clave -eq 'filename') { $m.Filename = $valor }
        elseif ($seccion -eq 'download' -and $clave -eq 'hash-format') { $m.HashFormat = $valor }
        elseif ($seccion -eq 'download' -and $clave -eq 'hash') { $m.Hash = $valor.ToLowerInvariant() }
        elseif ($seccion -eq 'download' -and $clave -eq 'url') { $m.Url = $valor }
        elseif ($seccion -eq 'update.modrinth' -and $clave -eq 'version') { $m.ModrinthVersion = $valor }
    }
    return [pscustomobject]$m
}

function Invoke-Modrinth ([string] $metodo, [string] $ruta, $cuerpo) {
    $p = @{ Method = $metodo; Uri = "$ModrinthApi$ruta"; UserAgent = 'Kald301/Guild2.0 sync-packs'; TimeoutSec = 30 }
    if ($null -ne $cuerpo) { $p.Body = ($cuerpo | ConvertTo-Json -Depth 4); $p.ContentType = 'application/json' }
    return Invoke-RestMethod @p
}

# ---------------------------------------------------------------------
#  Preparacion
# ---------------------------------------------------------------------

$Origen  = (Resolve-Path -LiteralPath $Origen).Path
$Destino = (Resolve-Path -LiteralPath $Destino).Path
$reporte = Join-Path $Destino 'packs-fallidos.txt'
$propios = @(Read-ListFile (Join-Path $Destino 'packs-propios.txt'))
$ignorar = @(Read-ListFile (Join-Path $Destino 'packs-ignorar.txt'))

# Un manifiesto viejo haria que verify-mods compare contra datos de otra
# corrida: se borra antes de empezar.
if (Test-Path -LiteralPath $Esperados) { Remove-Item -LiteralPath $Esperados -Force }

$items      = New-Object System.Collections.Generic.List[object]   # todo lo de la instancia
$bloqueados = New-Object System.Collections.Generic.List[object]   # no se publica: revision manual
$avisos     = New-Object System.Collections.Generic.List[string]
$listados   = New-Object System.Collections.Generic.List[object]   # .pw.toml obsoletos NO borrados
$carpetasOk = New-Object System.Collections.Generic.List[string]

foreach ($c in $Carpetas) {
    $src = Join-Path $Origen $c
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        Write-Step "$c : no existe en la instancia, se omite (no se toca el repo)."
        continue
    }
    $carpetasOk.Add($c)
    $dst = Join-Path $Destino $c
    $metas = @()
    if (Test-Path -LiteralPath $dst) { $metas = @(Get-ChildItem -LiteralPath $dst -Filter '*.pw.toml' -File | ForEach-Object { Read-Meta $_.FullName }) }

    # Sin -Force: los ocultos (desktop.ini, Thumbs.db) no son packs
    foreach ($i in @(Get-ChildItem -LiteralPath $src)) {
        $esDir = $i.PSIsContainer
        $rel   = "$c/$($i.Name)"
        $it = [pscustomobject]@{ Carpeta = $c; Nombre = $i.Name; Rel = $rel; Ruta = $i.FullName; EsDir = $esDir; Caso = ''; Sha1 = ''; Meta = $null; Detalle = '' }
        $items.Add($it)

        if (Test-Patron $rel $esDir $ignorar) { $it.Caso = 'generado'; continue }

        if (-not $esDir) {
            $it.Sha1 = Get-Sha $i.FullName 'sha1'
            foreach ($m in @($metas | Where-Object { $_.Filename -eq $i.Name })) {
                $h = if ($m.HashFormat) { Get-Sha $i.FullName $m.HashFormat } else { $null }
                if ($null -eq $h) {
                    $avisos.Add("$rel : $($m.Nombre) usa hash '$($m.HashFormat)', que no se puede comprobar aca. Se acepta por nombre de archivo.")
                } elseif ($h -ne $m.Hash) {
                    continue
                }
                if ($m.ModrinthVersion -eq '') { $it.Caso = 'declarado'; $it.Meta = $m }
                break
            }
            if ($it.Caso -ne '') { continue }
            if ($i.Extension -ieq '.zip') { $it.Caso = 'buscar'; continue }
        }

        if (Test-Patron $rel $esDir $propios) { $it.Caso = 'propio'; continue }
        $it.Caso = 'bloqueado'
    }
}

# ---------------------------------------------------------------------
#  Modrinth: se consulta TODO antes de tocar el repo. Si no hay red, sale
#  con 2 sin haber cambiado nada.
# ---------------------------------------------------------------------

$buscar = @($items | Where-Object { $_.Caso -eq 'buscar' })
$versiones = $null
$proyectos = @{}
if ($buscar.Count -gt 0) {
    try {
        $versiones = Invoke-Modrinth 'Post' '/version_files' @{ hashes = @($buscar | ForEach-Object { $_.Sha1 }); algorithm = 'sha1' }
        $ids = @($versiones.PSObject.Properties | ForEach-Object { $_.Value.project_id } | Sort-Object -Unique)
        if ($ids.Count -gt 0) {
            $q = [uri]::EscapeDataString((ConvertTo-Json -InputObject $ids -Compress))
            # En PowerShell 5.1 Invoke-RestMethod no enumera un array JSON:
            # con @(...) quedaria anidado. Asignado a una variable, si.
            $lista = Invoke-Modrinth 'Get' "/projects?ids=$q" $null
            foreach ($p in $lista) { $proyectos[$p.id] = $p }
        }
    } catch {
        Write-Fail "No se pudo consultar Modrinth: $($_.Exception.Message)"
        Write-Fail 'NO se toco nada de resourcepacks\ ni shaderpacks\ en el repo.'
        exit 2
    }
}

foreach ($it in $buscar) {
    $v = $null
    if ($null -ne $versiones -and $versiones.PSObject.Properties[$it.Sha1]) { $v = $versiones.($it.Sha1) }
    if ($null -eq $v) {
        $it.Caso = if (Test-Patron $it.Rel $false $propios) { 'propio' } else { 'bloqueado' }
        continue
    }
    $file = @($v.files | Where-Object { $_.hashes.sha1 -eq $it.Sha1 }) | Select-Object -First 1
    $proj = $proyectos[$v.project_id]
    if ($null -eq $file -or $null -eq $proj) {
        $it.Caso = 'bloqueado'
        $it.Detalle = 'Modrinth reconoce el hash pero no devolvio el archivo o el proyecto'
        continue
    }
    if ($file.filename -ne $it.Nombre) {
        $avisos.Add("$($it.Rel) : en Modrinth se llama '$($file.filename)'. El .pw.toml conserva el nombre de la instancia para no romper options.txt / iris.properties.")
    }
    $it.Caso = 'modrinth'
    $it.Meta = [pscustomobject]@{ Slug = $proj.slug; Titulo = $proj.title; ProjectId = $v.project_id; VersionId = $v.id; VersionNumber = $v.version_number; Url = $file.url; Sha512 = $file.hashes.sha512.ToLowerInvariant() }
}

# ---------------------------------------------------------------------
#  Aplicar cambios al repo, carpeta por carpeta
# ---------------------------------------------------------------------

$escritos = 0; $copiados = 0; $borrados = 0; $podados = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($c in $carpetasOk) {
    $dst = Join-Path $Destino $c
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $deCarpeta  = @($items | Where-Object { $_.Carpeta -eq $c })
    $conservarMeta = @{}   # nombre de .pw.toml -> $true
    $conservarRaw  = @{}   # nombre suelto -> $true

    foreach ($it in @($deCarpeta | Where-Object { $_.Caso -eq 'declarado' })) { $conservarMeta[$it.Meta.Nombre.ToLowerInvariant()] = $true }

    # --- .pw.toml de Modrinth (uno por archivo; si dos archivos son del
    #     mismo proyecto, el segundo lleva la version en el nombre) ---
    $porSlug = @{}
    foreach ($it in @($deCarpeta | Where-Object { $_.Caso -eq 'modrinth' })) {
        $base = $it.Meta.Slug
        if ($porSlug.ContainsKey($base) -or $conservarMeta.ContainsKey("$base.pw.toml")) {
            $base = "$base-" + ($it.Meta.VersionNumber -replace '[^A-Za-z0-9._-]', '_')
        }
        $porSlug[$it.Meta.Slug] = $true
        $nombreMeta = "$base.pw.toml"
        $conservarMeta[$nombreMeta.ToLowerInvariant()] = $true

        $texto = (@(
            "name = $(ConvertTo-TomlString $it.Meta.Titulo)",
            "filename = $(ConvertTo-TomlString $it.Nombre)",
            'side = "client"',
            '',
            '[download]',
            "url = $(ConvertTo-TomlString $it.Meta.Url)",
            'hash-format = "sha512"',
            "hash = $(ConvertTo-TomlString $it.Meta.Sha512)",
            '',
            '[update]',
            '  [update.modrinth]',
            "    mod-id = $(ConvertTo-TomlString $it.Meta.ProjectId)",
            "    version = $(ConvertTo-TomlString $it.Meta.VersionId)"
        ) -join "`n") + "`n"

        $ruta = Join-Path $dst $nombreMeta
        $actual = if (Test-Path -LiteralPath $ruta) { [System.IO.File]::ReadAllText($ruta) } else { $null }
        if ($actual -ne $texto) {
            [System.IO.File]::WriteAllText($ruta, $texto, $utf8)
            $escritos++
            Write-Step "$($it.Rel) -> Modrinth ($($it.Meta.Slug) $($it.Meta.VersionNumber)): $c\$nombreMeta"
        }
    }

    # --- Propios: se copian tal cual ---
    foreach ($it in @($deCarpeta | Where-Object { $_.Caso -eq 'propio' })) {
        $conservarRaw[$it.Nombre.ToLowerInvariant()] = $true
        $destinoItem = Join-Path $dst $it.Nombre
        if ($it.EsDir) {
            robocopy $it.Ruta $destinoItem /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy fallo con codigo $LASTEXITCODE copiando $($it.Rel)" }
            if ($LASTEXITCODE -gt 0) { $copiados++; Write-Step "$($it.Rel) -> propio: carpeta actualizada" }
        } elseif (-not (Test-Path -LiteralPath $destinoItem) -or (Get-Sha $destinoItem 'sha1') -ne $it.Sha1) {
            Copy-Item -LiteralPath $it.Ruta -Destination $destinoItem -Force
            $copiados++
            Write-Step "$($it.Rel) -> propio: se sube tal cual"
        }
    }

    foreach ($it in @($deCarpeta | Where-Object { $_.Caso -eq 'bloqueado' })) {
        $bloqueados.Add($it)
        Write-Warn "$($it.Rel) : NO se publica (no esta en Modrinth, no es propio ni generado). Ver packs-fallidos.txt."
    }

    # --- Limpieza: lo que hay en el repo y ya no corresponde ---
    $porItem = @{}
    foreach ($it in $deCarpeta) { $porItem[$it.Nombre.ToLowerInvariant()] = $it }
    $obsoletos = New-Object System.Collections.Generic.List[object]

    foreach ($d in @(Get-ChildItem -LiteralPath $dst -Force)) {
        $k = $d.Name.ToLowerInvariant()
        if (-not $d.PSIsContainer -and $d.Name -like '*.pw.toml') {
            if ($conservarMeta.ContainsKey($k)) { continue }
            $m = Read-Meta $d.FullName
            $fk = $m.Filename.ToLowerInvariant()
            if ($porItem.ContainsKey($fk) -and ($porItem[$fk].Caso -eq 'modrinth' -or $porItem[$fk].Caso -eq 'declarado')) {
                # Otro .pw.toml declara el mismo archivo (version vieja o
                # duplicado): lo que queda vigente ya lo cubre.
                Remove-Item -LiteralPath $d.FullName -Force
                $borrados++
                Write-Step "$c\$($d.Name) -> reemplazado (el archivo $($m.Filename) ya lo cubre otro .pw.toml)"
            } else {
                $motivoObs = if ($porItem.ContainsKey($fk)) { "su hash no coincide con $($m.Filename) de la instancia" } else { "$($m.Filename) ya no esta en la instancia" }
                $obsoletos.Add([pscustomobject]@{ Meta = $m; Motivo = $motivoObs })
            }
            continue
        }
        if ($conservarRaw.ContainsKey($k)) { continue }

        $motivo = 'ya no esta en la instancia'
        if ($porItem.ContainsKey($k)) {
            $motivo = switch ($porItem[$k].Caso) {
                'generado'  { 'lo genera cada cliente (packs-ignorar.txt)' }
                'modrinth'  { 'ahora lo baja Modrinth' }
                'declarado' { "lo declara $($porItem[$k].Meta.Nombre)" }
                default     { 'pack de terceros sin permiso para subirlo' }
            }
        }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force
        $borrados++
        Write-Step "$c\$($d.Name) -> se saca del repo: $motivo"
    }

    if ($obsoletos.Count -gt 0) {
        $frenado = $obsoletos.Count -gt $MaxPrune
        if ($frenado -or $PruneMode -eq 'listar') {
            $porque = if ($frenado) { "poda frenada: $($obsoletos.Count) obsoletos supera el limite de $MaxPrune (revisa la ruta ORIGEN)" } else { 'modo listar (PODA=listar en sync-modpack.bat)' }
            foreach ($o in $obsoletos) {
                $listados.Add([pscustomobject]@{ Toml = "$c\$($o.Meta.Nombre)"; Archivo = $o.Meta.Filename; Motivo = $o.Motivo; Porque = $porque })
                Write-Warn "$c\$($o.Meta.Nombre) : obsoleto ($($o.Motivo)). NO se borra: $porque."
            }
        } else {
            foreach ($o in $obsoletos) {
                Remove-Item -LiteralPath $o.Meta.Path -Force
                $podados++
                Write-Step "$c\$($o.Meta.Nombre) -> obsoleto podado ($($o.Motivo))"
            }
        }
    }
}

# ---------------------------------------------------------------------
#  Manifiesto para verify-mods.ps1
# ---------------------------------------------------------------------

$presentes = New-Object System.Collections.Generic.List[object]
$ausentes  = New-Object System.Collections.Generic.List[string]
foreach ($it in $items) {
    if ($it.Caso -eq 'generado' -or $it.Caso -eq 'bloqueado') { $ausentes.Add($it.Rel); continue }
    if ($it.EsDir) {
        $raiz = $it.Ruta.TrimEnd('\')
        foreach ($f in @(Get-ChildItem -LiteralPath $it.Ruta -File -Recurse -Force)) {
            $sub = $f.FullName.Substring($raiz.Length + 1) -replace '\\', '/'
            $presentes.Add([pscustomobject]@{ ruta = "$($it.Rel)/$sub"; sha1 = (Get-Sha $f.FullName 'sha1') })
        }
    } else {
        $presentes.Add([pscustomobject]@{ ruta = $it.Rel; sha1 = $it.Sha1 })
    }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Esperados) | Out-Null
$manifiesto = [pscustomobject]@{ generado = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); presentes = $presentes.ToArray(); ausentes = $ausentes.ToArray() }
[System.IO.File]::WriteAllText($Esperados, (ConvertTo-Json -InputObject $manifiesto -Depth 4), $utf8)

# ---------------------------------------------------------------------
#  Reporte
# ---------------------------------------------------------------------

$cuenta = @{}
foreach ($it in $items) { $cuenta[$it.Caso] = 1 + $(if ($cuenta.ContainsKey($it.Caso)) { $cuenta[$it.Caso] } else { 0 }) }
function Get-Cuenta ([string] $k) { if ($cuenta.ContainsKey($k)) { return $cuenta[$k] } else { return 0 } }

Write-Host ''
Write-Host '  PACKS'
Write-Host ("    Por Modrinth (.pw.toml)          : {0}" -f (Get-Cuenta 'modrinth'))
Write-Host ("    Declarados a mano (.pw.toml)     : {0}" -f (Get-Cuenta 'declarado'))
Write-Host ("    Propios (se suben tal cual)      : {0}" -f (Get-Cuenta 'propio'))
Write-Host ("    Generados en cada cliente        : {0}" -f (Get-Cuenta 'generado'))
Write-Host ("    NO publicados (revision manual)  : {0}" -f $bloqueados.Count)
Write-Host ("    Cambios en el repo               : {0} .pw.toml escritos, {1} copiados, {2} sacados, {3} podados" -f $escritos, $copiados, $borrados, $podados)

if ($bloqueados.Count -eq 0 -and $listados.Count -eq 0 -and $avisos.Count -eq 0) {
    if (Test-Path -LiteralPath $reporte) { Remove-Item -LiteralPath $reporte -Force }
    exit 0
}

$r = New-Object System.Collections.Generic.List[string]
$r.Add('============================================================')
$r.Add(' Reporte de resource packs y shaders - modpack Guild 2.0')
$r.Add(" Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$r.Add('============================================================')
$r.Add('')
if ($bloqueados.Count -gt 0) {
    $r.Add("NO PUBLICADOS - REVISION MANUAL ($($bloqueados.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add('Estan en la instancia pero no en Modrinth, ni declarados por un')
    $r.Add('.pw.toml, ni anotados como propios. NO se subieron al repo: subir')
    $r.Add('un pack de terceros tal cual es redistribuirlo. Opciones:')
    $r.Add('  - si esta en CurseForge: packwiz curseforge add <url> (el proximo')
    $r.Add('    sync lo reconoce por nombre y hash y lo deja como esta);')
    $r.Add('  - si lo hicimos nosotros: anotarlo en packs-propios.txt;')
    $r.Add('  - si lo genera un mod en cada cliente: anotarlo en packs-ignorar.txt.')
    $r.Add('')
    foreach ($b in $bloqueados) {
        $r.Add("  * $($b.Rel)$(if ($b.EsDir) { '/' })")
        if ($b.Detalle) { $r.Add("      motivo : $($b.Detalle)") }
    }
    $r.Add('')
}
if ($listados.Count -gt 0) {
    $r.Add("OBSOLETOS DETECTADOS - NO SE BORRO NADA ($($listados.Count))")
    $r.Add('------------------------------------------------------------')
    $r.Add("Por que no se borraron: $($listados[0].Porque)")
    $r.Add('')
    foreach ($l in $listados) {
        $r.Add("  * $($l.Toml)  ($($l.Archivo))")
        $r.Add("      motivo : $($l.Motivo)")
    }
    $r.Add('')
}
if ($avisos.Count -gt 0) {
    $r.Add("AVISOS ($($avisos.Count))")
    $r.Add('------------------------------------------------------------')
    foreach ($a in $avisos) { $r.Add("  * $a") }
    $r.Add('')
}
Set-Content -LiteralPath $reporte -Value $r -Encoding UTF8
Write-Warn "Hay cosas para revisar: $reporte"
exit 1
