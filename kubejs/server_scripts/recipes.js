// priority: 0
// Cambios de coste de recetas del pack.
// Cada receta se reemplaza con el mismo ID para que JEI/EMI y los libros de recetas sigan apuntando a ella.

ServerEvents.recipes(event => {
  // Mega Antorcha (Torchmaster): el tronco del centro pasa a ser un lingote de netherita.
  // Original: TTT / DLD / GLG
  event.remove({ id: 'torchmaster:megatorch' })
  event.shaped('torchmaster:megatorch', [
    'TTT',
    'DND',
    'GLG'
  ], {
    T: 'minecraft:torch',
    D: '#c:gems/diamond',
    N: '#c:ingots/netherite',
    G: '#c:storage_blocks/gold',
    L: '#minecraft:logs'
  }).id('torchmaster:megatorch')

  // Cristal de mar (Mermod): el diamante pasa a ser un bloque de diamante y da 3 en vez de 4.
  // Original: corazón del mar + diamante (sin forma) -> 4
  event.remove({ id: 'mermod:sea_crystal' })
  event.shapeless('3x mermod:sea_crystal', [
    'minecraft:heart_of_the_sea',
    'minecraft:diamond_block'
  ]).id('mermod:sea_crystal')

  // Collar de mar (Mermod): 3 cristales de mar arriba, estrella del Nether al centro
  // y 5 diamantes en U abajo.
  // Original: " A " / "A A" / " B " (A = lingote de hierro, B = cristal de mar)
  event.remove({ id: 'mermod:sea_necklace' })
  event.shaped('mermod:sea_necklace', [
    'CCC',
    'DSD',
    'DDD'
  ], {
    C: 'mermod:sea_crystal',
    D: 'minecraft:diamond',
    S: 'minecraft:nether_star'
  }).id('mermod:sea_necklace')

  // Harina de huesos minerales (SWEM): da 1 en vez de 16.
  // Original: harina de huesos + diamante + redstone + diorita + gusano estelar (sin forma) -> 16
  event.remove({ id: 'swem:mineral_bone_meal' })
  event.shapeless('swem:mineral_bone_meal', [
    'minecraft:bone_meal',
    'minecraft:diamond',
    'minecraft:redstone',
    'minecraft:diorite',
    'swem:star_worm'
  ]).id('swem:mineral_bone_meal')

  // Gusano estrella (SWEM): da 4 en vez de 16.
  // Original: 2x2 de roca de gusano estrella (#swem:star_worm_cobble) -> 16
  event.remove({ id: 'swem:star_worm' })
  event.shaped('4x swem:star_worm', [
    'CC',
    'CC'
  ], {
    C: '#swem:star_worm_cobble'
  }).id('swem:star_worm')

  // Herramientas y armaduras de netherita (SWEM): el original solo pide remaches de netherita.
  // Ahora, donde la versión de diamante lleva placa de diamante, la de netherita lleva placa de netherita.
  // Mismas formas que el original. R = remache de netherita, P = placa de netherita,
  // B = versión de diamante, S = cuerda (solo botas de montar).
  const netheriteGear = {
    horse_armor: ['R R', 'PBP', 'P P'],
    helmet: ['RPR', 'PBP'],
    chestplate: ['P P', 'RBR', 'RPR'],
    leggings: ['R R', 'PBP', 'R R'],
    boots_riding: ['R R', 'SBS', 'P P'],
    sword: ['P P', ' B ', 'R R'],
    pickaxe: ['PRP', ' B ', ' R '],
    axe: ['PR', 'PB', ' R'],
    shovel: ['P', 'B', 'R'],
    scythe: ['PPR', ' B ', ' R '],
    bow: ['RP', ' B', 'RP'],
    shield: ['PRP', ' B ', ' PR']
  }
  Object.keys(netheriteGear).forEach(gear => {
    const key = {
      R: 'swem:rivet_netherite',
      P: 'swem:plate_netherite',
      B: 'swem:' + gear + '_diamond'
    }
    if (gear == 'boots_riding') key.S = '#c:strings'
    event.remove({ id: 'swem:' + gear + '_netherite' })
    event.shaped('swem:' + gear + '_netherite', netheriteGear[gear], key).id('swem:' + gear + '_netherite')
  })

  // Caballos de piedra (SWEM): misma receta + una montura justo encima del bloque del centro.
  // Original: "S  " / "SSS" / "S S" (S = piedra, pizarra profunda, diorita, andesita o granito)
  const petRocks = ['stone', 'deepslate', 'diorite', 'andesite', 'granite']
  petRocks.forEach(rock => {
    event.remove({ id: 'swem:pet_rock_' + rock })
    event.shaped('swem:pet_rock_' + rock, [
      'SM ',
      'SSS',
      'S S'
    ], {
      S: 'minecraft:' + rock,
      M: 'minecraft:saddle'
    }).id('swem:pet_rock_' + rock)
  })

  // Tierra frondosa (BWG): receta nueva, BWG no trae ninguna para este bloque.
  // Turba + tierra (sin forma) -> 2 tierras frondosas.
  event.shapeless('2x biomeswevegone:lush_dirt', [
    'biomeswevegone:peat',
    'minecraft:dirt'
  ]).id('kubejs:lush_dirt_from_peat')
})
