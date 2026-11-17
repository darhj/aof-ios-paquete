import UIKit
import WebKit

/// Pantalla única de la app: un WKWebView a pantalla completa con el juego adentro.
///
/// Es el equivalente de MainActivity.java del proyecto Android, y sigue las mismas
/// decisiones. Todo el cliente (interfaz móvil incluida) ya está resuelto del lado web:
/// acá no se dibuja nada, sólo se le da al WebView el entorno que necesita.
final class JuegoViewController: UIViewController {

    /// Host + esquema propios. `localhost` no es decorativo: da la chance de que WebKit
    /// trate el origen como potencialmente confiable, y no cuesta nada.
    static let esquema = "arduz"
    static let inicio = "arduz://localhost/www/index.html"

    /// Chromium/WebKit mínimo razonable. Por debajo de iOS 15 no hay WebGL2 por defecto
    /// ni soporte de Range en el scheme handler: el juego no arranca bien.
    private var web: WKWebView!
    private let recursos = ManejadorRecursos()

    /// Freno del reinicio cuando el proceso de render muere (equivalente del
    /// onRenderProcessGone de Android): 2 reintentos, y el contador se olvida al minuto.
    private static var intentosRender = 0
    private static var ultimoIntento = Date.distantPast

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(recursos, forURLScheme: Self.esquema)

        // El audio del juego arranca con el primer toque (AudioManager), pero igual se
        // saca el candado de gesto para que no quede ninguna pista muda.
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.suppressesIncrementalRendering = false

        // Parche del contenedor: portapapeles y rescate del AudioContext. Se inyecta
        // ANTES de que corra el bundle (atDocumentStart) para que el juego encuentre las
        // dos cosas ya en su lugar.
        if let ruta = Bundle.main.url(forResource: "parche_ios", withExtension: "js"),
           let js = try? String(contentsOf: ruta, encoding: .utf8) {
            let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            cfg.userContentController.addUserScript(script)
            cfg.userContentController.add(self, name: "portapapeles")
        }

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs

        // Marca de "soy la app de iOS" en el user agent. applicationNameForUserAgent SOLO
        // reemplaza la cola del UA (su valor por defecto en iOS es "Mobile/15E148"), así
        // que se conserva ese token y se le suma " ArduzIOS": el UA queda
        //   Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15
        //   (KHTML, like Gecko) Mobile/15E148 ArduzIOS
        // Con eso el GATEWAY distingue la app de Safari en el mismo iPhone: con la web
        // móvil en mantenimiento (NavegadorCelular=0) la app entra igual
        // (PermitirAccesoIOS=1) — ver gateway/internal/relay/server.go, esAppIOS. Es lo
        // mismo que hace MainActivity en Android con " ArduzApk".
        // NO se toca el resto del UA: device.ts detecta el móvil con /iPhone|iPad|iPod/;
        // un UA de escritorio apagaría TODA la interfaz móvil ya trabajada.
        #if targetEnvironment(macCatalyst)
        // En la Mac el UA es de Macintosh y SIN "Mobile" (el cliente web decide la
        // interfaz de escritorio y el gateway nunca la bloquea): la marca va sola, sin
        // el token Mobile, que ahí metería al juego en los ajustes de celular.
        cfg.applicationNameForUserAgent = "ArduzMac"
        #else
        cfg.applicationNameForUserAgent = "Mobile/15E148 ArduzIOS"
        #endif

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        // Un juego no rebota ni hace scroll ni zoom: cualquiera de las tres cosas mueve el
        // lienzo justo cuando el jugador está caminando.
        web.scrollView.bounces = false
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.maximumZoomScale = 1
        web.scrollView.minimumZoomScale = 1
        // Sin gesto de "atrás" por deslizamiento: no hay a dónde volver y un roce en el
        // borde durante una pelea recargaría el juego.
        web.allowsBackForwardNavigationGestures = false

        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if let url = URL(string: Self.inicio) {
            web.load(URLRequest(url: url))
        }
    }

    // La pantalla no se apaga sola: el juego se mira sin tocarlo por ratos largos
    // (esperando, leyendo el chat) y al volver ya te mataron.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // Pantalla completa de verdad: sin barra de estado y con la barra de gestos atenuada.
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // Parado y acostado (sin boca abajo): la web tiene las dos disposiciones (tema.ts, "ACOSTADO").
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}

// MARK: - Navegación

extension JuegoViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // Lo nuestro se navega adentro.
        if url.scheme == Self.esquema {
            decisionHandler(.allow); return
        }
        // "Salir" del cliente móvil navega a arduzao.com. En Android eso cierra la app;
        // en iOS no existe forma legítima de cerrarse (exit(0) es rechazo por las guías de
        // Apple), así que se vuelve al principio, que es lo más parecido.
        // SOLO la raíz del sitio cuenta como "Salir" (igual que el APK, que compara la URL
        // exacta): cualquier otra página del dominio —un link de la consola, el ranking,
        // la wiki— es un link más y se abre AFUERA. Antes bastaba el host y un link a
        // https://arduzao.com/lo-que-sea reiniciaba el juego.
        let esRaiz = url.path.isEmpty || url.path == "/"
        if url.host == "arduzao.com" && esRaiz && (url.query ?? "").isEmpty {
            decisionHandler(.cancel)
            if let inicio = URL(string: Self.inicio) { webView.load(URLRequest(url: inicio)) }
            return
        }
        // Cualquier otro link (la web del juego, /CUARZOS…) se abre AFUERA: el WebView no
        // tiene barra de direcciones ni botón de volver, el jugador quedaría atrapado.
        decisionHandler(.cancel)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    /// El proceso de render murió (memoria). Se rearma la pantalla, con freno.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let ahora = Date()
        if ahora.timeIntervalSince(Self.ultimoIntento) > 60 { Self.intentosRender = 0 }
        Self.ultimoIntento = ahora
        Self.intentosRender += 1

        if Self.intentosRender > 2 {
            Self.intentosRender = 0
            avisar(titulo: "Sin memoria",
                   mensaje: "El juego se quedó sin memoria. Cerrá otras apps y volvé a abrirlo.")
            return
        }
        if let url = URL(string: Self.inicio) { webView.load(URLRequest(url: url)) }
    }
}

// MARK: - Diálogos de JavaScript

/// window.alert/confirm/prompt son la interfaz REAL del Mercado (comprar personaje, clave
/// de venta, publicar, ofertar). Sin WKUIDelegate, WKWebView los IGNORA y confirm()
/// devuelve false: comprar y publicar quedan rotos sin ningún mensaje de error.
extension JuegoViewController: WKUIDelegate {

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in
            completionHandler(a.textFields?.first?.text ?? "")
        })
        present(a, animated: true)
    }

    private func avisar(titulo: String, mensaje: String) {
        let a = UIAlertController(title: titulo, message: mensaje, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Aceptar", style: .default))
        present(a, animated: true)
    }
}

// MARK: - Puente del portapapeles

/// El esquema propio no es "secure context", así que `navigator.clipboard` no existe. Lo
/// único del cliente que lo usa son los botones "Copiar CBU" y "Copiar Alias" del Mercado,
/// que sin esto quedarían MUDOS (el `?.` corta la cadena y el jugador no ve ni un error).
/// parche_ios.js reemplaza navigator.clipboard por un puente a este handler.
extension JuegoViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "portapapeles", let texto = message.body as? String else { return }
        UIPasteboard.general.string = texto
    }
}
