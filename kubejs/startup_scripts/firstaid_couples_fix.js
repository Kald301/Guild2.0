// =====================================================================================================
// firstaid_couples_fix.js — v3 (2026-10-31)
// Separa First Aid Enhanced y Couples Mod al hacer clic derecho sobre OTRO JUGADOR.
//
// Probado (arnés con jugadores simulados, servidor dedicado) con:
//   NeoForge 21.1.262 · KubeJS 2101.7.2-build.377 · Rhino 2101.2.7-build.85
//   First Aid Enhanced 2.0.0 (firstaid, sadcat) · Couples Mod 1.0.3 (couplesmod, Linceros)
//   PlayerRevive 2.1.2 + CreativeCore 2.13.52 · Carry On 2.2.6
//
// Es un STARTUP script: va en kubejs/startup_scripts/ del CLIENTE y del SERVIDOR, y cualquier cambio
// exige reiniciar (no basta con /reload). En el cliente no hace nada (ver "Por qué solo en el servidor").
//
// QUÉ HACE (A = quien hace clic, B = el jugador sobre el que lo hace)
//   1. A agachado + mano principal vacía + SIN herramienta de First Aid en la secundaria:
//      solo Couples (beso / aceptar propuesta). Se le quita el clic a First Aid en los dos eventos y en las dos manos.
//   2. A de pie + mano vacía: First Aid abre su pantalla como siempre (el script no toca nada).
//   3. A con herramienta de First Aid en la mano principal: First Aid como siempre (no se toca nada;
//      Couples no actúa porque necesita la mano vacía).
//   4. A con cualquier otro objeto en la mano principal: no se toca nada.
//   5. B no es un jugador: no se toca nada.
//   6. A agachado + mano principal vacía + herramienta de First Aid en la SECUNDARIA: cuenta como herramienta,
//      First Aid funciona y se le quita el clic a Couples (constante BLOQUEAR_COUPLES_CON_HERRAMIENTA_EN_SECUNDARIA).
//   Jugadores falsos (desplegadores de Create, etc.) y espectadores: no se toca nada.
//   Si falta First Aid o Couples, el script no hace nada.
//
// POR QUÉ ASÍ (comprobado en el código de los mods y de NeoForge 21.1.262; detalles en INFORME.md)
//   - First Aid escucha EntityInteractSpecific y EntityInteract con prioridad LOWEST y abre la pantalla con la
//     mano principal vacía SIN mirar el agachado, ya en el primer evento (INTERACT_AT). Sus objetos médicos
//     (vendas, morfina...) actúan por la mano en la que estén, también la secundaria.
//   - Couples escucha solo EntityInteract, prioridad NORMAL, mano principal, agachado + mano vacía.
//   - Por eso este script cancela en LOW: Couples (NORMAL), PlayerRevive y Carry On (HIGH) y los demás mods
//     ya han actuado, y solo queda fuera First Aid (LOWEST). La v2 cancelaba EntityInteractSpecific en HIGH,
//     lo que además tapaba a otros mods en NORMAL/LOW sin necesidad.
//   - Por qué solo en el servidor: First Aid abre su pantalla con un paquete que manda el SERVIDOR; el cliente
//     no decide nada. Cancelar en el cliente no evita que se envíe el paquete y, si se cancelara con un
//     resultado "consumido", el cliente dejaría de enviar el segundo paquete (INTERACT) y Couples no recibiría
//     su evento. Además Sophisticated Backpacks usa ese evento en el cliente para abrir la mochila de otro.
//   - El agachado se lee en el servidor del propio paquete del clic (ServerGamePacketListenerImpl.handleInteract
//     hace setShiftKeyDown con su indicador), así que coincide con lo que el jugador hacía al pulsar.
//   - No hace falta setCancellationResult: en el servidor el resultado solo decide el brazo que se mueve; cuál
//     es la siguiente mano lo decide el cliente.
//
// DEPURACIÓN: poner DEBUG = true (y reiniciar). Cada decisión sobre un jugador escribe una línea en
// logs/kubejs/startup.log con el prefijo [firstaid_couples_fix]; como mucho 30 líneas cada 10 s.
//
// HISTORIAL: v1 llamaba a player.level() (en KubeJS "level" es una propiedad) y cerraba el juego.
//            v2 NUNCA llegaba a cancelar nada: declaraba "const player" DENTRO de un try { }, y este Rhino lanza
//            "TypeError: redeclaration of var player" en cuanto entra en ese bloque (probado). Su catch lo tapaba
//            y devolvía false, así que First Aid se seguía abriendo. Además solo miraba la mano principal y
//            cancelaba EntityInteractSpecific en HIGH.
//
// REGLA DE ESTILO PARA ESTE RHINO: dentro de funciones y bloques usar SIEMPRE let (nunca const);
// const solo en el nivel superior del archivo.
// =====================================================================================================

const VERSION = 'v3 (2026-10-31)'
const DEBUG = false

// Caso 6: agachado + mano principal vacía + herramienta de First Aid en la secundaria.
// true  = cuenta como herramienta: First Aid funciona y Couples NO besa (separación total).
// false = no se toca nada en ese caso (First Aid se abre por la secundaria y Couples también besa).
const BLOQUEAR_COUPLES_CON_HERRAMIENTA_EN_SECUNDARIA = true

const PREFIJO = '[firstaid_couples_fix]'

// --- Qué cuenta como "herramienta de First Aid": lo que hace que First Aid actúe al hacer clic en otro jugador.
// Plan A (clases de First Aid; se cargan en el primer clic, protegidas con try/catch):
const CLASES_HERRAMIENTA = [
  'ichttt.mods.firstaid.api.healing.ItemHealing',        // venda, tirita
  'ichttt.mods.firstaid.common.items.ItemTraumaAid',     // morfina, torniquete, férula, antibióticos...
  'ichttt.mods.firstaid.common.items.ItemEmptySyringe'   // jeringa vacía (extracción de sangre)
]
// Plan B (siempre activo, por si cambian las clases): ids de First Aid Enhanced 2.0.0 y sus etiquetas de vendas.
const IDS_HERRAMIENTA = [
  'firstaid:bandage', 'firstaid:plaster', 'firstaid:morphine', 'firstaid:empty_syringe',
  'firstaid:antibiotics', 'firstaid:antibiotics_pack', 'firstaid:antibiotic_syringe', 'firstaid:adrenaline',
  'firstaid:ethanol', 'firstaid:pressure_bandage', 'firstaid:blood_syringe', 'firstaid:blood_bag',
  'firstaid:splint', 'firstaid:trauma_kit', 'firstaid:saline', 'firstaid:purified_water',
  'firstaid:elastic_bandage', 'firstaid:surgical_kit', 'firstaid:tourniquet', 'firstaid:opium'
]
const ETIQUETAS_HERRAMIENTA = ['firstaid:bandages', 'firstaid:plasters']

const $EventPriority = Java.loadClass('net.neoforged.bus.api.EventPriority')

// Solo tiene sentido con los dos mods. Si falta uno, no se registra nada.
const ACTIVO = Platform.isLoaded('firstaid') && Platform.isLoaded('couplesmod')
const HAY_PLAYERREVIVE = Platform.isLoaded('playerrevive')

// ------------------------------------------------------------------ avisos (una sola vez)
let errorAvisado = false
function avisarError(donde, e) {
  if (errorAvisado) return
  errorAvisado = true
  console.error(PREFIJO + ' Error en ' + donde + '; el script deja pasar el clic sin tocarlo para no romper nada: ' + e)
}

// ------------------------------------------------------------------ depuración con límite
let debugVentana = 0
let debugLineas = 0
let debugOmitidas = 0
function depurar(texto) {
  if (!DEBUG) return
  let ahora = Date.now()
  if (ahora - debugVentana > 10000) {
    if (debugOmitidas > 0) console.info(PREFIJO + ' (' + debugOmitidas + ' líneas de depuración omitidas)')
    debugVentana = ahora
    debugLineas = 0
    debugOmitidas = 0
  }
  if (debugLineas < 30) {
    debugLineas++
    console.info(PREFIJO + ' ' + texto)
  } else {
    debugOmitidas++
  }
}

// ------------------------------------------------------------------ herramientas de First Aid
let clases = null          // se cargan en el primer clic (no en el arranque: así no se adelanta la inicialización de First Aid)
let planAFallido = false
function cargarClases() {
  if (clases !== null) return
  clases = []
  for (let i = 0; i < CLASES_HERRAMIENTA.length; i++) {
    let nombre = CLASES_HERRAMIENTA[i]
    try {
      clases.push(Java.loadClass(nombre))
    } catch (e) {
      if (!planAFallido) {
        planAFallido = true
        console.warn(PREFIJO + ' No se pudo cargar ' + nombre + ' (¿cambió First Aid?). Se usa la lista de ids y etiquetas.')
      }
    }
  }
}

function esHerramientaFirstAid(stack) {
  if (stack.isEmpty()) return false
  // Plan A: clase del objeto
  cargarClases()
  let item = stack.getItem()
  for (let i = 0; i < clases.length; i++) {
    try {
      if (item instanceof clases[i]) return true
    } catch (e) { /* si instanceof falla, sigue el plan B */ }
  }
  // Plan B: id y etiquetas
  let id = String(stack.getId())
  if (IDS_HERRAMIENTA.indexOf(id) >= 0) return true
  for (let i = 0; i < ETIQUETAS_HERRAMIENTA.length; i++) {
    if (stack.hasTag(ETIQUETAS_HERRAMIENTA[i])) return true
  }
  return false
}

// PlayerRevive (opcional): si B se está desangrando, PlayerRevive se queda el clic (HIGH) y Couples no actúa
// igualmente; el script no debe adelantarse a él.
let $PlayerReviveServer = null
let playerReviveFallido = false
function seDesangra(jugador) {
  if (!HAY_PLAYERREVIVE || playerReviveFallido) return false
  try {
    if ($PlayerReviveServer === null) $PlayerReviveServer = Java.loadClass('team.creative.playerrevive.server.PlayerReviveServer')
    return $PlayerReviveServer.isBleeding(jugador)
  } catch (e) {
    playerReviveFallido = true
    console.warn(PREFIJO + ' No se pudo consultar PlayerRevive: ' + e)
    return false
  }
}

// ------------------------------------------------------------------ LA REGLA (único sitio donde se decide)
// Devuelve:
//   'SOLO_COUPLES'   -> agachado + mano principal vacía + sin herramienta en la secundaria (caso 1)
//   'SOLO_FIRSTAID'  -> agachado + mano principal vacía + herramienta en la secundaria (caso 6)
//   null             -> no se toca nada (todos los demás casos)
function decidir(event) {
  if (event.getSide().isClient()) return null              // en el cliente no se hace nada (ver cabecera)
  let objetivo = event.getTarget()
  if (objetivo == null || !objetivo.isPlayer()) return null // caso 5: solo jugadores
  let actor = event.getEntity()
  if (actor.isFakePlayer() || actor.isSpectator()) return null
  if (!actor.isShiftKeyDown()) return null                 // de pie: First Aid como siempre (caso 2)
  if (!actor.getMainHandItem().isEmpty()) return null      // casos 3 y 4: hay algo en la mano principal
  return esHerramientaFirstAid(actor.getOffhandItem()) ? 'SOLO_FIRSTAID' : 'SOLO_COUPLES'
}

function describir(event, fase, regla, accion) {
  let a = event.getEntity()
  return 'DEBUG ' + fase + ' lado=' + (event.getSide().isClient() ? 'cliente' : 'servidor') +
    ' mano=' + (String(event.getHand()) == 'MAIN_HAND' ? 'principal' : 'secundaria') +
    ' agachado=' + a.isShiftKeyDown() + ' P=' + a.getMainHandItem().getId() + ' S=' + a.getOffhandItem().getId() +
    ' objetivo=' + event.getTarget().getType() + ' -> ' + (regla == null ? 'sin cambios' : regla) + ' / ' + accion
}

// Cancela en LOW (después de Couples, PlayerRevive y Carry On; antes de First Aid) si la regla es SOLO_COUPLES.
// Vale para los dos eventos y las dos manos: así First Aid no puede abrirse por la secundaria.
function bloquearFirstAid(event, fase) {
  try {
    let regla = decidir(event)
    let cancelar = regla == 'SOLO_COUPLES'
    if (DEBUG && event.getTarget() != null && event.getTarget().isPlayer()) depurar(describir(event, fase, regla, cancelar ? 'cancelo (First Aid no lo ve)' : 'no toco'))
    if (cancelar) event.setCanceled(true)
  } catch (e) {
    avisarError(fase, e)
  }
}

// Cancela en HIGH (antes de Couples) solo en el caso 6 y en la mano principal (Couples solo mira esa mano).
// First Aid sigue abriéndose por el evento INTERACT_AT y por la mano secundaria, que no se tocan.
function bloquearCouples(event, fase) {
  try {
    if (!BLOQUEAR_COUPLES_CON_HERRAMIENTA_EN_SECUNDARIA) return
    if (String(event.getHand()) != 'MAIN_HAND') return
    let regla = decidir(event)
    let cancelar = regla == 'SOLO_FIRSTAID' && !seDesangra(event.getTarget())
    if (DEBUG && event.getTarget() != null && event.getTarget().isPlayer()) depurar(describir(event, fase, regla, cancelar ? 'cancelo (Couples no lo ve)' : 'no toco'))
    if (cancelar) event.setCanceled(true)
  } catch (e) {
    avisarError(fase, e)
  }
}

if (ACTIVO) {
  NativeEvents.onEvent($EventPriority.LOW,
    'net.neoforged.neoforge.event.entity.player.PlayerInteractEvent$EntityInteractSpecific',
    event => bloquearFirstAid(event, 'EntityInteractSpecific/LOW'))
  NativeEvents.onEvent($EventPriority.LOW,
    'net.neoforged.neoforge.event.entity.player.PlayerInteractEvent$EntityInteract',
    event => bloquearFirstAid(event, 'EntityInteract/LOW'))
  NativeEvents.onEvent($EventPriority.HIGH,
    'net.neoforged.neoforge.event.entity.player.PlayerInteractEvent$EntityInteract',
    event => bloquearCouples(event, 'EntityInteract/HIGH'))
  console.info(PREFIJO + ' ' + VERSION + ' cargado (DEBUG=' + DEBUG + ', caso 6 bloquea Couples=' + BLOQUEAR_COUPLES_CON_HERRAMIENTA_EN_SECUNDARIA + ')')
} else {
  console.warn(PREFIJO + ' ' + VERSION + ': falta First Aid (firstaid) o Couples Mod (couplesmod); el script no hace nada.')
}
