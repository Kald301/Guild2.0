// Weather2 (weather2-neoforge-1.21.0-2.8.7): bloquea "/weather2 summon ..." para quien no sea op.
// Por que: en WeatherCommand el nodo "summon" encadena .requires(hasPermission(2)).requires(dimension en la lista);
// Brigadier se queda solo con el segundo, asi que cualquier jugador puede invocar tornados (verificado en desastres-fase2).
// Como funciona: ServerEvents.command se dispara (NeoForge CommandEvent) antes de ejecutar cualquier comando,
// lo teclee un jugador, un bloque de comandos o la consola. Si la ruta del comando pasa por weather2 -> summon
// y la fuente no tiene permiso >= 2, se cancela y se avisa al jugador.
// Nota Rhino (pack Guild): nada de "const" dentro de try/bloques; solo let dentro de funciones.

const W2_NIVEL_MINIMO = 2
// pares [raiz, subcomando] bloqueados para no-op; "*" = cualquier subcomando
const W2_BLOQUEADOS = [
  ['weather2', 'summon']
]

function w2RutaBloqueada(ctx) {
  // recorre el contexto y sus hijos (redirecciones como /execute ... run)
  let c = ctx
  let guard = 0
  while (c != null && guard++ < 16) {
    let nodes = c.getNodes()
    for (let i = 0; i < nodes.size(); i++) {
      let name = String(nodes.get(i).getNode().getName())
      for (let k = 0; k < W2_BLOQUEADOS.length; k++) {
        let par = W2_BLOQUEADOS[k]
        if (name == par[0]) {
          if (par[1] == '*') return par[0]
          if (i + 1 < nodes.size() && String(nodes.get(i + 1).getNode().getName()) == par[1]) return par[0] + ' ' + par[1]
        }
      }
    }
    c = c.getChild()
  }
  return null
}

ServerEvents.command(event => {
  let ctx = event.getParseResults().getContext()
  let src = ctx.getSource()
  if (src.hasPermission(W2_NIVEL_MINIMO)) return
  let ruta = w2RutaBloqueada(ctx)
  if (ruta == null) return
  src.sendFailure(Text.red('/' + ruta + ' solo para administradores (op).'))
  console.info('[weather2_comandos_solo_op] bloqueado /' + event.getInput() + ' de ' + src.getTextName())
  event.cancel()
})
