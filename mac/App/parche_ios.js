/*
 * parche_ios.js — Dos remiendos del CONTENEDOR, inyectados antes de que corra el juego.
 *
 * Están acá y no en el cliente web a propósito: son cosas que sólo pasan adentro de un
 * WKWebView con esquema propio. El cliente web no se toca.
 */
(function () {
  "use strict";

  /* 1) PORTAPAPELES ------------------------------------------------------------------
   * Con un esquema propio la página no es "secure context", así que navigator.clipboard
   * no existe. Lo único que lo usa son los botones "Copiar CBU" y "Copiar Alias" del
   * Mercado; sin esto quedan mudos y el jugador no se entera de nada. Se reemplaza por un
   * puente al UIPasteboard nativo, con la MISMA firma (devuelve una promesa).
   */
  try {
    var puente = window.webkit && window.webkit.messageHandlers &&
                 window.webkit.messageHandlers.portapapeles;
    if (puente && (!navigator.clipboard || !navigator.clipboard.writeText)) {
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: {
          writeText: function (texto) {
            puente.postMessage(String(texto));
            return Promise.resolve();
          },
        },
      });
    }
  } catch (e) { /* si no se puede, se pierde sólo el botón de copiar */ }

  /* 2) AUDIO QUE REVIVE --------------------------------------------------------------
   * WebKit usa un estado NO estándar, "interrupted", después de una llamada telefónica,
   * de Siri o de mandar la app a segundo plano. El AudioManager del cliente sólo llama a
   * resume() si el estado es "suspended", así que con "interrupted" el sonido queda
   * MUERTO por el resto de la sesión.
   *
   * Acá se envuelve el constructor de AudioContext para que cada contexto que el juego
   * cree se reanime solo al volver a primer plano. Es un remiendo del contenedor: el
   * arreglo de fondo (comparar contra "running" en vez de "suspended") va del lado del
   * cliente y sirve para todas las plataformas.
   */
  try {
    var Ctor = window.AudioContext || window.webkitAudioContext;
    if (Ctor) {
      var vivos = [];
      var Envuelto = function (opciones) {
        var ctx = new Ctor(opciones);
        vivos.push(ctx);
        return ctx;
      };
      Envuelto.prototype = Ctor.prototype;
      window.AudioContext = Envuelto;
      window.webkitAudioContext = Envuelto;

      var revivir = function () {
        for (var i = 0; i < vivos.length; i++) {
          var c = vivos[i];
          if (c && c.state !== "running" && typeof c.resume === "function") {
            try { c.resume(); } catch (e) { /* nada que hacer */ }
          }
        }
      };
      document.addEventListener("visibilitychange", function () {
        if (!document.hidden) revivir();
      });
      window.addEventListener("focus", revivir);
      // Cualquier toque también sirve de excusa para reanimarlo.
      window.addEventListener("touchend", revivir, { passive: true });
    }
  } catch (e) { /* sin audio no se rompe el juego */ }
})();
