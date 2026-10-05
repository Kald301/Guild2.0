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

> Si el script avisó **"quedaron casos que necesitan revisión manual, u obsoletos detectados que no se
> borraron"** → leer `mods-fallidos.txt` ANTES de hacer push (ver secciones 3 y 6).

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
| 7 | Corre `verify-mods.ps1` (poda de obsoletos + verificación real de descarga) |

Notas:
- `/MIR` es **espejo**, pero solo de los `.jar`: los `.pw.toml` no entran en el filtro y
  `packwiz curseforge detect` solo agrega, nunca borra. Por eso un mod que saco de CurseForge
  dejaba su `.pw.toml` vivo para siempre (así pasó con Alex's Caves y Citadel). Desde ahora
  eso lo resuelve la **poda de obsoletos** del paso 7 (sección 3).
- Busca `packwiz.exe` en el PATH y, si no está, en `%USERPROFILE%\go\bin\packwiz.exe`.
- Al principio del `.bat` se configuran las rutas de origen/destino, `MAX_MB=90`,
  `PODA=listar|borrar` y `MAX_PODA=10`.

---

## 3. Qué hace `verify-mods.ps1` (y por qué existe)

Tres fases, en este orden. Todo queda anotado en `mods-fallidos.txt`, separado por motivo.

**1. Duplicados conocidos** (antes de instalar nada). Se borran solos, porque el mod no se pierde:
- un `.jar` suelto en `mods\` que ya declara un `.pw.toml` → sobra el `.jar`;
- el mismo `.jar` declarado por un `.pw.toml` de CurseForge **y** por otro de Modrinth/URL
  directa → sobra el de CurseForge.

**2. Poda de obsoletos.** Un `.pw.toml` cuyo `.jar` ya no está en la instancia de CurseForge
(ni por nombre ni por hash) es un mod que saqué, o la versión vieja de uno que cambié por un
fork. Si queda, los jugadores lo siguen bajando y el server (que copia de la instancia) no lo
tiene → "conexión perdida" por canales que el server no conoce.
- `PODA=listar` (en el `.bat`): solo los lista en `mods-fallidos.txt`, **no borra nada**.
- `PODA=borrar`: los borra. A los jugadores se les borra el `.jar` solo en el próximo arranque:
  packwiz-installer borra lo que él mismo instaló y salió del pack (lo dice el log:
  `Deleted X (removed from pack)`). **No** toca lo que no instaló él (un `.jar` copiado a mano).
- Si aparecen más de `MAX_PODA` obsoletos de una vez **no se borra ninguno** (casi seguro es la
  ruta `ORIGEN` mal puesta).
- `mods-reemplazos.txt`: pares `viejo -> nuevo` (forks/sucesores). El reporte dice "reemplazado
  por X", y si los dos siguen instalados en CurseForge **frena** en vez de borrar: hay que sacar
  el viejo de la instancia (si no, el server queda con los dos).
- `mods-conservar.txt`: `.pw.toml` que nunca se podan aunque no estén en la instancia.

**3. Instalación de prueba.** Algunos autores bloquean la descarga de su mod por la API de
CurseForge → al jugador le falla la instalación. El script **lo detecta probando una
instalación real**: corre `packwiz-installer-bootstrap.jar` contra el `pack.toml` local, en una
carpeta descartable fuera del repo, y clasifica cada mod que falla:

| Motivo del fallo | Qué hace |
|---|---|
| Bloqueado por el autor ("excluded from the CurseForge API") | **Override**: borra su `.pw.toml` y deja el `.jar` real en `mods\`, copiado desde la instancia |
| Duplicado CurseForge + Modrinth del mismo `.jar` | Borra la copia de CurseForge |
| Error de red (sin conexión, 429, 5xx) | **No toca nada**; espera y reintenta. Si sigue, revisión manual |
| Hash inválido, 404/403, motivo desconocido | **No toca nada**: revisión manual, con la línea del log como evidencia |

Repite el ciclo (hasta 4 rondas) hasta que la instalación de prueba termine limpia. Ningún mod
se borra "a ciegas": si el motivo no es uno conocido, el `.pw.toml` queda como estaba.

⚠️ **Esto es esperado, no es un bug:** `packwiz curseforge detect` (paso 6) vuelve a convertir
esos jars a metadata de CurseForge en **cada** sincronización. Por eso el paso 7 corre siempre
después y lo vuelve a arreglar. No hay que "arreglarlo de una vez por todas".

---

## 4. Códigos de salida de `verify-mods.ps1`

| Código | Significa | Qué hago |
|--------|-----------|----------|
| 0 | Pack sano, se instaló completo sin errores | Commit y push tranquilo |
| 1 | Arregló lo que pudo, **quedan casos manuales** u obsoletos detectados sin borrar (`PODA=listar`) | Leer `mods-fallidos.txt` **antes** de publicar |
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
- `mods-fallidos.txt` lista **obsoletos detectados** (con `PODA=listar`): si la lista está bien,
  cambiar a `PODA=borrar`; si alguno tiene que quedarse, anotarlo en `mods-conservar.txt`.
- Cambio un mod por un fork → anotar el par en `mods-reemplazos.txt` (opcional: el viejo se poda
  igual, pero así queda documentado y el script frena si quedaron los dos instalados).

Para esos casos existen `packwiz curseforge add`, `packwiz modrinth add` y `packwiz url add`.
**No son el flujo normal** — el flujo normal es la sección 1.

Si agrego un mod con `packwiz url add` que **no** instalo en CurseForge, anotarlo en
`mods-conservar.txt`; si no, la poda lo toma como obsoleto.

---

## 7. Rutas importantes

| Qué | Dónde |
|-----|-------|
| Instancia de CurseForge (origen) | `C:\Users\0_0\curseforge\minecraft\Instances\Guild 2.1 - copia` |
| Este repo (destino) | `C:\Users\0_0\Documents\GitHub\Guild2.0` |
| Carpeta temporal de verificación | `%LOCALAPPDATA%\packwiz-verify\instance` (se borra sola) |
| Log completo del installer | `%LOCALAPPDATA%\packwiz-verify\install.log` |
| Reporte de fallos | `mods-fallidos.txt` (raíz del repo; se borra solo si todo salió OK) |
| Pares fork/reemplazo | `mods-reemplazos.txt` (raíz del repo) |
| Excepciones a la poda | `mods-conservar.txt` (raíz del repo) |
| URL del pack para los jugadores | `https://raw.githubusercontent.com/Kald301/Guild2.0/main/pack.toml` |

---

## 8. Troubleshooting

- **"Hash invalid" en muchísimos archivos a la vez** → era el problema de line endings.
  Ya resuelto con `.gitattributes` (`* -text`); no debería repetirse.
- **502 / error al descargar desde GitHub** → CDN de GitHub caído un rato. Reintentar.
- **"Conexión perdida — el canal `x:y` no está en el lado del servidor"** → el cliente tiene un
  mod que el server no. Casi siempre es un `.pw.toml` obsoleto: mirar la sección "OBSOLETOS" de
  `mods-fallidos.txt`. Si el `.jar` llegó a la instancia del jugador por otro lado (copiado a
  mano), packwiz-installer no lo borra: hay que sacarlo a mano esa única vez.
- **Código 2: "no se encontró java"** → abrir la consola con un Java en el PATH, o reinstalarlo.
- **Código 2: falta el bootstrap jar** → bajar `packwiz-installer-bootstrap.jar` de
  https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest a la raíz del repo.
