// Separa First Aid Enhanced y Couples Mod cuando se hace clic derecho sobre otro jugador:
//   - Clic derecho normal con la mano vacia (o con objeto medico) -> First Aid (pantalla de tratamiento)
//   - Shift + clic derecho con la mano vacia                      -> solo Couples Mod (beso / aceptar propuesta)
//
// First Aid abre su pantalla con cualquier clic de mano vacia sobre un jugador, sin mirar Shift,
// y escucha dos eventos (EntityInteractSpecific y EntityInteract) con prioridad LOWEST.
// Couples escucha solo EntityInteract con prioridad NORMAL y usa Shift + mano vacia.
// Este script cancela el evento entre ambos para que First Aid ignore Shift + mano vacia.
//
// v2: NO usar player.level() -> en KubeJS "level" es una propiedad (getLevel de KubeJS) y
//     llamarla como funcion lanzaba TypeError y cerraba el juego. El lado se obtiene con
//     event.getSide(). Todo va dentro de try/catch para que un error nunca cierre el juego.
//
// Es un startup script: los cambios requieren reiniciar el juego/servidor (no basta con /reload).

const $EventPriority = Java.loadClass('net.neoforged.bus.api.EventPriority')

let errorAvisado = false

function shiftManoVaciaSobreJugador(event) {
  try {
    if (event.getSide().isClient()) return false
    if (String(event.getHand()) != 'MAIN_HAND') return false
    const player = event.getEntity()
    if (!player.isShiftKeyDown()) return false
    if (!player.getMainHandItem().isEmpty()) return false
    return event.getTarget().isPlayer()
  } catch (e) {
    if (!errorAvisado) {
      errorAvisado = true
      console.error('[firstaid_couples_fix] Error, el script se ignora para no cerrar el juego: ' + e)
    }
    return false
  }
}

// Primer aviso del clic (interactAt): llega antes y First Aid lo usa para abrir su pantalla.
NativeEvents.onEvent($EventPriority.HIGH,
  'net.neoforged.neoforge.event.entity.player.PlayerInteractEvent$EntityInteractSpecific',
  event => {
    if (shiftManoVaciaSobreJugador(event)) event.setCanceled(true)
  })

// Segundo aviso (interact): Couples (NORMAL) se ejecuta antes. Si no uso el clic,
// se cancela aqui (LOW) para que First Aid (LOWEST) no abra su pantalla.
NativeEvents.onEvent($EventPriority.LOW,
  'net.neoforged.neoforge.event.entity.player.PlayerInteractEvent$EntityInteract',
  event => {
    if (shiftManoVaciaSobreJugador(event)) event.setCanceled(true)
  })
