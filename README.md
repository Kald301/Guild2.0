# Guild 2.0 — Modpack

Modpack de Minecraft **NeoForge 1.21.1** (NeoForge 21.1.249), gestionado con **packwiz**.
Se arma sincronizando desde mi instancia de CurseForge hacia este repo; los jugadores lo
usan con **Prism Launcher** y se les actualiza solo al abrir la instancia.

---

## 1. Uso del día a día

1. Instalo / pruebo / saco mods **normalmente en mi instancia de CurseForge**.
2. Doble click en `sync-modpack.bat` y espero (el paso 7 tarda: instala el pack entero de prueba).
3. Si terminó en verde:

```bat
git status
git add .
git commit -m "actualizacion de mods y configs"
git push
```

Listo. Los jugadores no hacen nada: se actualiza solo la próxima vez que abran Prism.

> Si el script avisó **"quedaron casos que necesitan revisión manual"** → leer `mods-fallidos.txt`
> ANTES de hacer push (ver sección 5 y 7).

---

## 2. Qué hace `sync-modpack.bat`

| # | Paso |
|---|------|
| 1 | `robocopy /MIR` de `mods\` (solo `*.jar`) desde la instancia de CurseForge |
| 2 | `robocopy /MIR` de `config\` (si existe en origen) |
| 3 | `robocopy /MIR` de `kubejs\` (si existe) |
| 4 | `robocopy /MIR` de `resourcepacks\` (si existe) |
| 5 | `robocopy /MIR` de `shaderpacks\` (si existe) |
| 6 | `packwiz curseforge detect` + `packwiz refresh` |
| 7 | Corre `verify-mods.ps1` (verificación real de descarga) |

Notas:
- `/MIR` es **espejo**: lo que borro en CurseForge se borra acá.
- Busca `packwiz.exe` en el PATH y, si no está, en `%USERPROFILE%\go\bin\packwiz.exe`.
- Las rutas de origen/destino y el `MAX_MB=90` están al principio del `.bat`.

---

## 3. Qué hace `verify-mods.ps1` (y por qué existe)

Algunos autores bloquean la descarga de su mod por la API de CurseForge → al jugador le
falla la instalación. El script **lo detecta probando una instalación real**: corre
`packwiz-installer-bootstrap.jar` contra el `pack.toml` local, en una carpeta descartable
fuera del repo, y mira qué `.jar` no se pudieron bajar.

Con cada mod que falla hace una de dos cosas, **solo, sin que yo toque nada**:
- **Lo convierte a override** → borra su `.pw.toml` y deja el `.jar` real dentro de `mods\`,
  copiado desde la instancia de CurseForge. Ya no depende de ninguna API.
- **Borra el duplicado** → si ese mod ya estaba agregado desde Modrinth/URL directa, la copia
  de CurseForge sobra y se elimina.

Repite el ciclo (hasta 4 rondas) hasta que la instalación de prueba termine limpia.

⚠️ **Esto es esperado, no es un bug:** `packwiz curseforge detect` (paso 6) vuelve a convertir
esos jars a metadata de CurseForge en **cada** sincronización. Por eso el paso 7 corre siempre
después y lo vuelve a arreglar. No hay que "arreglarlo de una vez por todas".

---

## 4. Códigos de salida de `verify-mods.ps1`

| Código | Significa | Qué hago |
|--------|-----------|----------|
| 0 | Pack sano, se instaló completo sin errores | Commit y push tranquilo |
| 1 | Arregló lo que pudo, **quedan casos manuales** | Leer `mods-fallidos.txt` **antes** de publicar |
| 2 | **No se pudo verificar** (falta `java` en el PATH o falta el bootstrap jar) | No probó nada: no asumir que está bien |
| 3 | Falló de un modo no interpretable | No asumir que está bien; ver el log |
| 4 | El verificador se cortó por un error propio | No asumir que está bien; ver el error |

Con 2, 3 o 4 el `.bat` corta y **no** muestra los pasos de git.

---

## 5. Setup de un jugador nuevo

1. Instalar **Prism Launcher**.
2. Crear instancia **Minecraft 1.21.1 + NeoForge 21.1.249**.
3. Copiar `packwiz-installer-bootstrap.jar` dentro de la carpeta `.minecraft` de la instancia
   (la misma donde está `mods/`).
4. En Prism: *Editar instancia → Settings → Custom commands → Pre-launch command*:

```
"$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://raw.githubusercontent.com/Kald301/Guild2.0/main/pack.toml
```

5. Iniciar. La primera vez baja todo; después solo baja lo que cambió.

---

## 6. Cuándo tocar algo a mano

Solo en estos casos, que son la excepción:

- Un mod aparece en **"REQUIERE REVISIÓN MANUAL"** de `mods-fallidos.txt` por pesar más de
  **90 MB** (no se convierte a override para no chocar con el límite de 100 MB por archivo de
  GitHub).
- Hace falta agregar un mod que no está ni en CurseForge ni en Modrinth.

Para esos casos existen `packwiz curseforge add`, `packwiz modrinth add` y `packwiz url add`.
**No son el flujo normal** — el flujo normal es la sección 1.

---

## 7. Rutas importantes

| Qué | Dónde |
|-----|-------|
| Instancia de CurseForge (origen) | `C:\Users\0_0\curseforge\minecraft\Instances\Guild 2.1 - copia` |
| Este repo (destino) | `C:\Users\0_0\Documents\GitHub\Guild2.0` |
| Carpeta temporal de verificación | `%LOCALAPPDATA%\packwiz-verify\instance` (se borra sola) |
| Log completo del installer | `%LOCALAPPDATA%\packwiz-verify\install.log` |
| Reporte de fallos | `mods-fallidos.txt` (raíz del repo; se borra solo si todo salió OK) |
| URL del pack para los jugadores | `https://raw.githubusercontent.com/Kald301/Guild2.0/main/pack.toml` |

---

## 8. Troubleshooting

- **"Hash invalid" en muchísimos archivos a la vez** → era el problema de line endings.
  Ya resuelto con `.gitattributes` (`* -text`); no debería repetirse.
- **502 / error al descargar desde GitHub** → CDN de GitHub caído un rato. Reintentar.
- **Código 2: "no se encontró java"** → abrir la consola con un Java en el PATH, o reinstalarlo.
- **Código 2: falta el bootstrap jar** → bajar `packwiz-installer-bootstrap.jar` de
  https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest a la raíz del repo.
