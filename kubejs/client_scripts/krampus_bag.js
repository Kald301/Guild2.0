// priority: 0
// Cancela también la predicción del cliente: sin esto, Item.use del mod se ejecuta en el cliente
// (sonido local duplicado, swing y shrink fantasma). El loot real lo decide el server script.

ItemEvents.rightClicked('born_in_chaos_v1:krampuss_bag', event => {
  event.cancel()
})
