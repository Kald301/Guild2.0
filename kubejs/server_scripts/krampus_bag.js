// priority: 0
// Krampus's Bag: reemplaza el loot del mod (KrampussBagPriShchielchkiePKMProcedure)
// por solo carbón + rareloot + unusualloot, sin ramas de compatibilidad con otros mods.

const $BuiltInRegistries = Java.loadClass('net.minecraft.core.registries.BuiltInRegistries')
const $Registries = Java.loadClass('net.minecraft.core.registries.Registries')
const $ResourceLocation = Java.loadClass('net.minecraft.resources.ResourceLocation')
const $TagKey = Java.loadClass('net.minecraft.tags.TagKey')
const $ItemStack = Java.loadClass('net.minecraft.world.item.ItemStack')
const $ItemEntity = Java.loadClass('net.minecraft.world.entity.item.ItemEntity')
const $SoundSource = Java.loadClass('net.minecraft.sounds.SoundSource')

const KRAMPUS_BAG = 'born_in_chaos_v1:krampuss_bag'
const RARE_LOOT_TAG = $TagKey.create($Registries.ITEM, $ResourceLocation.parse('born_in_chaos_v1:rareloot'))
const UNUSUAL_LOOT_TAG = $TagKey.create($Registries.ITEM, $ResourceLocation.parse('born_in_chaos_v1:unusualloot'))

// Igual que Mth.nextInt(random, min, max): entero entre min y max, ambos incluidos
const randInt = (random, min, max) => min + random.nextInt(max - min + 1)

// Suelta un ItemEntity como el mod: 1 bloque por encima del jugador, 25 ticks de pickup delay
function dropAtPlayer(level, player, stack) {
  if (stack.isEmpty()) return
  const entity = new $ItemEntity(level, player.getX(), player.getY() + 1.0, player.getZ(), stack)
  entity.setPickUpDelay(25)
  level.addFreshEntity(entity)
}

// Ítem al azar (uniforme) de un tag, o ItemStack vacío si el tag no existe o está vacío
function randomStackFromTag(tagKey, random) {
  const holder = $BuiltInRegistries.ITEM.getRandomElementOf(tagKey, random)
  return holder.isPresent() ? new $ItemStack(holder.get().value()) : $ItemStack.EMPTY
}

ItemEvents.rightClicked(KRAMPUS_BAG, event => {
  const { player, item, hand, level } = event
  const random = level.getRandom()
  const bagItem = item.getItem()

  player.swing(hand, true)

  item.shrink(1)
  // El mod llama addCooldown después del shrink, cuando el stack ya está vacío (AIR),
  // así que en la práctica su cooldown nunca se aplica. Aquí se usa el ítem guardado antes.
  player.getCooldowns().addCooldown(bagItem, 20)

  const sound = $BuiltInRegistries.SOUND_EVENT.get($ResourceLocation.parse('item.armor.equip_leather'))
  level.playSound(null, player.getX(), player.getY(), player.getZ(), sound, $SoundSource.NEUTRAL, 1.0, 1.0)

  const littleSnowflake = $BuiltInRegistries.PARTICLE_TYPE.get($ResourceLocation.parse('born_in_chaos_v1:littlesnowflake'))
  const snowCloud = $BuiltInRegistries.PARTICLE_TYPE.get($ResourceLocation.parse('born_in_chaos_v1:snowcloud'))
  if (littleSnowflake) level.sendParticles(littleSnowflake, player.getX(), player.getY() + 1.0, player.getZ(), 8, 0.4, 0.3, 0.4, 0.2)
  if (snowCloud) level.sendParticles(snowCloud, player.getX(), player.getY() + 1.0, player.getZ(), 4, 0.3, 0.2, 0.3, 0.1)

  // Los bucles re-tiran el límite en cada vuelta, igual que el Java del mod
  // (for (i = 0; i < Mth.nextInt(...); i++)), para conservar su distribución real.

  // Carbón: 7-15 entidades de 1 carbón cada una
  for (let i = 0; i < randInt(random, 7, 15); i++) {
    dropAtPlayer(level, player, new $ItemStack($BuiltInRegistries.ITEM.get($ResourceLocation.parse('minecraft:coal'))))
  }

  // 45 %: 1 ítem de born_in_chaos_v1:rareloot
  if (Math.random() < 0.45) {
    dropAtPlayer(level, player, randomStackFromTag(RARE_LOOT_TAG, random))
  }

  // 90 % (una sola tirada): 1-3 ítems de born_in_chaos_v1:unusualloot, cada uno elegido por separado
  if (Math.random() < 0.9) {
    for (let i = 0; i < randInt(random, 1, 3); i++) {
      dropAtPlayer(level, player, randomStackFromTag(UNUSUAL_LOOT_TAG, random))
    }
  }

  // Cancela PlayerInteractEvent.RightClickItem: Item.use del mod no llega a ejecutarse.
  // Va al final porque cancel() corta la ejecución del callback.
  event.cancel()
})
