// priority: 0
// Zombies Break & Build (1.6.3): impide CONSTRUIR (pero no romper ni ver a través de paredes)
// a monstruos voladores/acuáticos, detectados por navegación / control de movimiento.
//
// Cómo funciona: BuildAction.canExecute solo mira ConfigData.ignoreBuildEntityIdSet
// (public, no final, transient -> nunca se guarda en el TOML). Reasignamos ese campo con
// un Set nuevo que incluye los ids descubiertos. Estar solo en la lista de build no quita
// el Goal ni afecta a romper (el filtro de ZBB solo excluye si está en build Y break).
//
// Depende de nombres internos de ZBB: ConfigManager.getConfigSnapshot(), ConfigSnapshot.data(),
// ConfigData.ignoreBuildEntityIdSet. Si cambian, el script se desactiva solo y avisa en el log.

const LOG_PREFIX = '[ZBB-noBuild]'
const EXCLUDED_IDS = ['minecraft:drowned']
const REAPPLY_INTERVAL_TICKS = 400 // ~20 s

const $BuiltInRegistries = Java.loadClass('net.minecraft.core.registries.BuiltInRegistries')
const $ResourceLocation = Java.loadClass('net.minecraft.resources.ResourceLocation')
const $Mob = Java.loadClass('net.minecraft.world.entity.Mob')
const $PathfinderMob = Java.loadClass('net.minecraft.world.entity.PathfinderMob')
const $FlyingPathNavigation = Java.loadClass('net.minecraft.world.entity.ai.navigation.FlyingPathNavigation')
const $WaterBoundPathNavigation = Java.loadClass('net.minecraft.world.entity.ai.navigation.WaterBoundPathNavigation')
const $FlyingMoveControl = Java.loadClass('net.minecraft.world.entity.ai.control.FlyingMoveControl')
const $HashSet = Java.loadClass('java.util.HashSet')
const $Set = Java.loadClass('java.util.Set')
const $ArrayList = Java.loadClass('java.util.ArrayList')

// Ids descubiertos (ArrayList<String> de Java). Se guarda en `global` para sobrevivir a /reload,
// que vuelve a ejecutar los server_scripts y además hace que ZBB cree un ConfigData nuevo.
if (!global.zbbNoBuildIds) global.zbbNoBuildIds = new $ArrayList()
const discovered = global.zbbNoBuildIds

let $ConfigManager = null
let disabled = false

try {
  $ConfigManager = Java.loadClass('com.tik.zbb.config.ConfigManager')
} catch (e) {
  disabled = true
  console.warn(`${LOG_PREFIX} No se pudo acceder a ConfigManager, posible cambio de versión del mod (${e}). Script desactivado.`)
}

function disable(reason, error) {
  if (disabled) return
  disabled = true
  console.warn(`${LOG_PREFIX} ${reason}, posible cambio de versión del mod (${error}). Script desactivado.`)
}

function getConfigData() {
  return $ConfigManager.getConfigSnapshot().data()
}

// Reasigna ignoreBuildEntityIdSet = Set anterior + ids nuevos. Devuelve los ids realmente añadidos.
function addToIgnoreBuildSet(idStrings) {
  const data = getConfigData()
  const current = data.ignoreBuildEntityIdSet
  const merged = new $HashSet(current)
  const added = []
  idStrings.forEach(idString => {
    const id = $ResourceLocation.parse(idString)
    if (!merged.contains(id)) {
      merged.add(id)
      added.push(idString)
    }
  })
  if (added.length === 0) return added

  data.ignoreBuildEntityIdSet = $Set.copyOf(merged)

  // Comprobación de que la escritura del campo llegó al objeto Java real
  const check = getConfigData().ignoreBuildEntityIdSet
  if (!check.contains($ResourceLocation.parse(added[0]))) {
    throw new Error('la reasignación de ignoreBuildEntityIdSet no tuvo efecto')
  }
  return added
}

function isFlyingOrAquatic(mob) {
  if (mob.getType().getCategory().name() != 'MONSTER') return false
  const navigation = mob.getNavigation()
  return navigation instanceof $FlyingPathNavigation
    || navigation instanceof $WaterBoundPathNavigation
    || mob.getMoveControl() instanceof $FlyingMoveControl
}

function handleMob(entity) {
  if (disabled) return
  // ZBB solo actúa sobre PathfinderMob; el resto sería ruido en el log
  if (!(entity instanceof $Mob) || !(entity instanceof $PathfinderMob)) return

  const key = $BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType())
  if (key == null) return
  const idString = String(key.toString())
  if (EXCLUDED_IDS.indexOf(idString) !== -1) return
  if (discovered.contains(idString)) return
  if (!isFlyingOrAquatic(entity)) return

  try {
    const added = addToIgnoreBuildSet([idString])
    discovered.add(idString)
    if (added.length > 0) {
      console.info(`${LOG_PREFIX} añadido ${idString}`)
    } else {
      console.info(`${LOG_PREFIX} ${idString} ya estaba en ignoreBuildEntityIdList del TOML`)
    }
  } catch (e) {
    disable('No se pudo modificar ignoreBuildEntityIdSet', e)
  }
}

// Vuelve a aplicar los ids ya descubiertos (tras /reload ZBB crea un ConfigData nuevo sin ellos)
function reapplyDiscovered() {
  if (disabled || discovered.isEmpty()) return
  try {
    const ids = []
    discovered.forEach(id => ids.push(String(id)))
    const added = addToIgnoreBuildSet(ids)
    if (added.length > 0) {
      console.info(`${LOG_PREFIX} config de ZBB recargada: reaplicados ${added.length} ids (${added.join(', ')})`)
    }
  } catch (e) {
    disable('No se pudo reaplicar ignoreBuildEntityIdSet', e)
  }
}

EntityEvents.spawned(event => {
  if (event.level.isClientSide()) return
  handleMob(event.entity)
})

let tickCounter = 0
let initialScanDone = false

ServerEvents.tick(event => {
  if (disabled) return

  // Una sola vez tras cargar/recargar el script: revisa los mobs que ya estaban en el mundo,
  // porque no vuelven a disparar el evento de spawn.
  if (!initialScanDone) {
    initialScanDone = true
    try {
      event.server.getAllLevels().forEach(level => {
        level.getAllEntities().forEach(entity => handleMob(entity))
      })
    } catch (e) {
      console.warn(`${LOG_PREFIX} Falló el escaneo inicial de entidades (${e})`)
    }
    reapplyDiscovered()
    return
  }

  if (++tickCounter < REAPPLY_INTERVAL_TICKS) return
  tickCounter = 0
  reapplyDiscovered()
})
