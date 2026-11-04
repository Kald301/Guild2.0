// =============================================================================
// Weather2: LISTA BLANCA de bloques que los tornados pueden arrancar
// =============================================================================
// Este script crea el tag de bloques  #guild:tornado_puede_romper
// y Weather2 lo usa porque en config/Weather2/Tornado.toml está puesto:
//     Storm_Tornado_grabBlocks = true
//     Storm_Tornado_GrabCond_List = true
//     Storm_Tornado_GrabListBlacklistMode = false
//     Storm_Tornado_GrabList = "#guild:tornado_puede_romper"
// Lo que NO esté en el tag, el tornado no lo toca.
// Si borras este script, el tag queda vacío y los tornados no arrancan nada.
//
// CÓMO EDITAR
//   Solo hay que tocar las dos listas de abajo. Cada línea es una de estas:
//     'minecraft:oak_leaves'        un bloque concreto (su ID; míralo con F3)
//     '#minecraft:small_flowers'    un tag: todos los bloques que lo tienen
//                                   (con F3, los tags del bloque salen con #)
//     '@dtbwg'                      TODOS los bloques de un mod (cuidado: incluye
//                                   ramas, tierra, etc. de ese mod)
//     /^dtbwg:.*_leaves$/           un patrón sobre el ID (expresión regular,
//                                   entre barras y sin comillas)
//   Cada línea termina en coma. Lo que va detrás de // es un comentario:
//   para activar un ejemplo, borra las // del principio de su línea.
//
//   TORNADO_PUEDE_ROMPER  = lo que el tornado puede arrancar.
//   TORNADO_NUNCA         = excepciones: se quitan aunque entren por un tag
//                           o un patrón de la primera lista.
//
// DESPUÉS DE CAMBIARLO
//   Cierra y vuelve a abrir el mundo (o reinicia el servidor). /reload
//   actualiza el tag, pero Weather2 recuerda lo que ya decidió para cada bloque.
//
// COMPROBARLO
//   - logs/kubejs/server.log dice al cargar cuántos bloques quedan en la lista:
//       [tornado_lista_blanca] 256 bloques en #guild:tornado_puede_romper (0 quitados por TORNADO_NUNCA)
//   - Mira un bloque con F3: si a la derecha sale #guild:tornado_puede_romper,
//     el tornado lo puede arrancar.
//   - Si escribes mal un ID o un tag, el log avisa ("No such element" o 0 bloques).
// =============================================================================

// Lo que el tornado SÍ puede arrancar
const TORNADO_PUEDE_ROMPER = [
  '#dynamictrees:leaves',          // hojas de Dynamic Trees y de sus addons (BWG, BOP, Terralith, RU, Quark, Croptopia, BetterEnd)

  // Ejemplos desactivados:
  // '#minecraft:small_flowers',   // flores pequeñas
  // '#minecraft:tall_flowers',    // flores altas
  // 'minecraft:short_grass',      // hierba baja
  // 'minecraft:tall_grass',       // hierba alta
  // 'minecraft:fern',             // helecho
  // 'biomeswevegone:leaf_pile',   // un bloque concreto de un mod
  // /^dtbwg:.*_leaves$/,          // patrón: las hojas del addon de BWG
]

// Excepciones: lo que NUNCA puede arrancar, aunque entre por la lista de arriba
const TORNADO_NUNCA = [
  // 'dynamictrees:cherry_leaves', // ejemplo: respetar las hojas de cerezo
]

// ---- A partir de aquí no hace falta tocar nada ------------------------------
const TORNADO_TAG = 'guild:tornado_puede_romper'
const TORNADO_TAG_SI = 'guild:tornado_interno_si'   // tags auxiliares: se vacían al final
const TORNADO_TAG_NO = 'guild:tornado_interno_no'

ServerEvents.tags('block', event => {
  // 1) Resolver las dos listas a bloques concretos (los tags se expanden aquí,
  //    así una excepción puede quitar un bloque que entró por un tag).
  TORNADO_PUEDE_ROMPER.forEach(filtro => event.add(TORNADO_TAG_SI, filtro))
  TORNADO_NUNCA.forEach(filtro => event.add(TORNADO_TAG_NO, filtro))
  let si = event.get(TORNADO_TAG_SI).getObjectIds()
  let no = event.get(TORNADO_TAG_NO).getObjectIds()

  let excluidos = {}
  for (let i = 0; i < no.size(); i++) excluidos[String(no.get(i))] = true

  // 2) El tag final: bloque a bloque, sin las excepciones ni repetidos.
  let puestos = {}
  let total = 0
  let quitados = 0
  for (let i = 0; i < si.size(); i++) {
    let id = String(si.get(i))
    if (puestos[id]) continue
    puestos[id] = true
    if (excluidos[id]) { quitados++; continue }
    event.add(TORNADO_TAG, id)
    total++
  }
  event.removeAll(TORNADO_TAG_SI)
  event.removeAll(TORNADO_TAG_NO)

  console.info('[tornado_lista_blanca] ' + total + ' bloques en #' + TORNADO_TAG + ' (' + quitados + ' quitados por TORNADO_NUNCA)')
  if (total == 0) console.warn('[tornado_lista_blanca] la lista está vacía: los tornados no arrancarán ningún bloque')
})
