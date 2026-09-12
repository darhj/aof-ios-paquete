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
    static let esquema = "aoforever"
    static let inicio = "aoforever://localhost/www/index.html"

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
        // Guardado de archivos del juego (video de la grabación F11/Opciones, captura PNG):
        // WKWebView no descarga blobs, así que el cliente los manda por pedazos en base64 a
        // este handler (web/src/game/video/descargas.ts) y acá se escriben en
        // Documentos/AOForever y se abre la hoja de compartir. Ver archivoMensaje.
        cfg.userContentController.add(self, name: "archivo")
        // Orientación (Opciones → Orientación del cliente, web/src/config/orientacion.ts):
        // "vertical" (default) u "horizontal". Ver aplicarOrientacion.
        cfg.userContentController.add(self, name: "orientacion")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs

        // Token propio en el User-Agent: el GATEWAY lo usa para distinguir esta app
        // nativa de Safari en un iPhone (o del APK de Android), y así poder exigirle
        // SOLO a ella una versión mínima (VersionGateway_IOS) sin afectar a nadie más —
        // por ejemplo, para forzar "actualizá desde la App Store" tras un parche
        // importante. `applicationNameForUserAgent` es propiedad de WKWebViewConfiguration
        // (no de WKWebView — hay que ponerla ACÁ, antes de crear el WKWebView, si no no
        // tiene efecto) y AGREGA el token al UA normal de WebKit, no lo reemplaza: nada
        // más del sitio (device.ts, etc.) deja de funcionar. Debe coincidir con
        // `marcaClienteIOSApp` en el gateway (internal/relay/estado.go) y con la
        // detección del lado web (config/device.ts, iosApp).
        let versionApp = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        cfg.applicationNameForUserAgent = "AOForeverIOSApp/\(versionApp)"

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        // OPACO: con isOpaque=false, Core Animation compone TODA la capa del WebView con
        // blending en cada frame — un impuesto de GPU permanente sobre un canvas a
        // pantalla completa (se notaba como FPS bajos/trabado en el juego). El fondo
        // negro contra el flash blanco de arranque lo cubren backgroundColor +
        // underPageBackgroundColor + la UILaunchScreen negra: no hace falta transparencia.
        web.isOpaque = true
        web.backgroundColor = .black
        web.underPageBackgroundColor = .black
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
        // NO se toca el user agent: device.ts detecta el móvil con /iPhone|iPad|iPod/ sobre
        // el UA, que WKWebView siempre trae. Un UA de escritorio apagaría TODA la interfaz
        // móvil ya trabajada.

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
    /// Orientaciones permitidas AHORA: arranca vertical (la interfaz de siempre) y pasa a
    /// apaisado cuando el cliente lo pide (mensaje "orientacion"). El Info.plist declara
    /// las dos familias; esta máscara es la que manda en cada momento.
    private static var orientaciones: UIInterfaceOrientationMask = .portrait
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { Self.orientaciones }

    /// Aplica el modo pedido por el juego y le pide al sistema que rote YA (iOS 16+:
    /// requestGeometryUpdate; antes: attemptRotationToDeviceOrientation). Idempotente.
    fileprivate func aplicarOrientacion(_ modo: String) {
        let nueva: UIInterfaceOrientationMask = modo == "horizontal" ? .landscape : .portrait
        if nueva == Self.orientaciones { return }
        Self.orientaciones = nueva
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: nueva)) { _ in }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
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
        // "Salir" del cliente móvil navega a aoforever.cc. En Android eso cierra la app;
        // en iOS no existe forma legítima de cerrarse (exit(0) es rechazo por las guías de
        // Apple), así que se vuelve al principio, que es lo más parecido.
        // SOLO la raíz del sitio cuenta como "Salir" (igual que el APK, que compara la URL
        // exacta): cualquier otra página del dominio —un link de la consola, el ranking,
        // la wiki— es un link más y se abre AFUERA. Antes bastaba el host y un link a
        // https://aoforever.cc/lo-que-sea reiniciaba el juego.
        let esRaiz = url.path.isEmpty || url.path == "/"
        if url.host == "aoforever.cc" && esRaiz && (url.query ?? "").isEmpty {
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
        switch message.name {
        case "portapapeles":
            if let texto = message.body as? String { UIPasteboard.general.string = texto }
        case "archivo":
            if let cuerpo = message.body as? [String: Any] { archivoMensaje(cuerpo) }
        case "orientacion":
            if let modo = message.body as? String { aplicarOrientacion(modo) }
        default:
            break
        }
    }
}

// MARK: - Guardado de archivos (video de la grabación, captura PNG)

/// WKWebView no descarga blobs (`<a download>` no hace nada adentro de la app). El cliente
/// manda el archivo POR PEDAZOS en base64 (web/src/game/video/descargas.ts):
///   {op:"abrir", nombre, mime, bytes} → {op:"datos", b64} × N → {op:"cerrar"} | {op:"cancelar"}
/// Se escribe en Documentos/AOForever (visible en la app Archivos gracias a
/// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace del Info.plist) y al cerrar se
/// abre la hoja de compartir: "Guardar video" (Fotos), "Guardar en Archivos", AirDrop, etc.
/// Los mensajes de un WKScriptMessageHandler llegan EN ORDEN al hilo principal, así que no
/// hace falta sincronizar. Nada de esto toca el juego: un pedazo malo descarta el archivo.
extension JuegoViewController {
    private static var archivoHandle: FileHandle?
    private static var archivoURL: URL?

    private func archivoMensaje(_ m: [String: Any]) {
        let op = m["op"] as? String ?? ""
        switch op {
        case "abrir":
            archivoDescartar()
            var nombre = (m["nombre"] as? String ?? "")
                .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            if nombre.isEmpty || nombre.hasPrefix(".") {
                nombre = "AOForever_\(Int(Date().timeIntervalSince1970))"
            }
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let dir = docs.appendingPathComponent("AOForever", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(nombre)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
                Self.archivoHandle = try FileHandle(forWritingTo: url)
                Self.archivoURL = url
            } catch {
                archivoDescartar()
            }
        case "datos":
            guard let h = Self.archivoHandle,
                  let b64 = m["b64"] as? String,
                  let datos = Data(base64Encoded: b64) else {
                // Pedazo ilegible: el archivo quedaría corrupto, mejor descartarlo entero.
                if Self.archivoHandle != nil { archivoDescartar() }
                return
            }
            h.write(datos)
        case "cerrar":
            guard let h = Self.archivoHandle, let url = Self.archivoURL else { return }
            h.closeFile()
            Self.archivoHandle = nil
            Self.archivoURL = nil
            let hoja = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            // iPad: la hoja es un popover y exige un ancla; en iPhone se ignora.
            if let pop = hoja.popoverPresentationController {
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            present(hoja, animated: true)
        case "cancelar":
            archivoDescartar()
        default:
            break
        }
    }

    /// Cierra y borra lo que haya quedado a medio escribir (error o cancelación).
    private func archivoDescartar() {
        Self.archivoHandle?.closeFile()
        if let url = Self.archivoURL { try? FileManager.default.removeItem(at: url) }
        Self.archivoHandle = nil
        Self.archivoURL = nil
    }
}
