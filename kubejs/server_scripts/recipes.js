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
})
