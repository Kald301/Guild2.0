// priority: 0
// First Aid Enhanced: sus recetas aceptan la sal de otros mods, no solo firstaid:salt.
// Solo vale la sal suelta (en partícula o polvo). Los bloques de sal (bloque, saco, mena, suelo de sal)
// y los trozos grandes siguen sin valer.
//
// Cómo funciona:
// 1. Etiqueta propia #kubejs:firstaid_salt = firstaid:salt + todo lo que haya en las etiquetas comunes
//    de sal (FA_SAL_FUENTES), menos lo que sea un bloque y lo que esté en FA_SAL_EXCLUIR.
//    Se arma sola: un mod nuevo que etiquete su sal en #c:salt o #c:dusts/salt entra sin tocar nada.
// 2. Las dos recetas de First Aid que piden sal se reemplazan con el mismo ID para pedir esa etiqueta:
//    - firstaid:antibiotics (pedía firstaid:salt)
//    - firstaid:saline_unprepared (pedía #forge:salt, que solo tiene firstaid:salt)
// Las demás recetas de First Aid no usan sal. La sal de First Aid se sigue fabricando igual
// (horno: muestra de agua de mar -> sal).
//
// Al recargar, el log del servidor (logs/kubejs/server.log) lista lo que entró y lo que quedó fuera.

const FA_SAL_TAG = 'kubejs:firstaid_salt'

// Etiquetas de donde se toma la sal.
const FA_SAL_FUENTES = ['c:salt', 'c:salts', 'c:dusts/salt', 'forge:salt']

// Sal suelta que ningún mod etiqueta (vacío por ahora). Ejemplo: 'mimod:sea_salt'
const FA_SAL_EXTRA = []

// Nunca entran, aunque algún mod los etiquete como sal.
// croptopia:mountain_salt es un trozo de sal de roca (botín raro de naufragio), no sal suelta.
const FA_SAL_EXCLUIR = ['croptopia:mountain_salt']

ServerEvents.tags('item', event => {
  if (!Platform.isLoaded('firstaid')) return

  const BlockItem = Java.loadClass('net.minecraft.world.item.BlockItem')

  // getObjectIds() resuelve etiquetas anidadas y descarta ids de mods que no están instalados.
  // Llamarlo hace que KubeJS ejecute este evento con las etiquetas ya cargadas (no en la pasada previa).
  const candidatos = ['firstaid:salt']
  FA_SAL_FUENTES.forEach(fuente => {
    event.get(fuente).getObjectIds().forEach(id => candidatos.push(String(id)))
  })
  FA_SAL_EXTRA.forEach(id => candidatos.push(id))

  // En la pasada previa de KubeJS no hay registro: no se loguea nada (esa pasada se descarta).
  const pasadaPrevia = event.getElementIds().isEmpty()

  const vistos = {}
  const dentro = []
  const fuera = []
  candidatos.forEach(id => {
    if (vistos[id]) return
    vistos[id] = true
    if (FA_SAL_EXCLUIR.indexOf(id) >= 0) {
      fuera.push(id + ' (excluido a mano)')
      return
    }
    if (!Item.exists(id)) {
      fuera.push(id + ' (no existe)')
      return
    }
    if (Item.getItem(id) instanceof BlockItem) {
      fuera.push(id + ' (es un bloque)')
      return
    }
    dentro.push(id)
  })

  event.add(FA_SAL_TAG, dentro)

  if (!pasadaPrevia) {
    console.info('[firstaid_sal] #' + FA_SAL_TAG + ' = ' + dentro.join(', '))
    if (fuera.length > 0) console.info('[firstaid_sal] fuera: ' + fuera.join(', '))
  }
})

ServerEvents.recipes(event => {
  if (!Platform.isLoaded('firstaid')) return

  // Antibióticos. Original: champiñón marrón + azúcar + harina de hueso + firstaid:salt + agua purificada -> 3
  event.remove({ id: 'firstaid:antibiotics' })
  event.shapeless('3x firstaid:antibiotics', [
    'minecraft:brown_mushroom',
    'minecraft:sugar',
    'minecraft:bone_meal',
    '#' + FA_SAL_TAG,
    'firstaid:purified_water'
  ]).id('firstaid:antibiotics')

  // Suero sin preparar (luego se hornea a suero). Original: agua purificada + #forge:salt + panel de vidrio
  // + cuerda + pepita de hierro -> 1
  event.remove({ id: 'firstaid:saline_unprepared' })
  event.shapeless('firstaid:saline_unprepared', [
    'firstaid:purified_water',
    '#' + FA_SAL_TAG,
    'minecraft:glass_pane',
    'minecraft:string',
    'minecraft:iron_nugget'
  ]).id('firstaid:saline_unprepared')
})
