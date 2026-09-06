import Foundation
import WebKit

/// Sirve el juego desde adentro del paquete de la app, bajo `aoforever://localhost/www/…`.
///
/// ES EL EQUIVALENTE iOS DEL WebViewAssetLoader DE ANDROID, y existe por el mismo motivo:
/// con `file://` el WKWebView usa un ORIGEN OPACO y se rompe medio cliente —
///   1) localStorage tira SecurityError → se caen options.ts, servers.ts, runtime.ts y main.ts,
///   2) fetch() sobre file:// está bloqueado → no cargan los .json de init/, los mapas ni version.txt,
///   3) Assets.load() de PixiJS usa fetch + createImageBitmap: mismo problema,
///   4) abrir un wss:// desde un origen opaco es terreno gris.
///
/// En Android eso se resuelve con un origen https REAL. En iOS ESO NO SE PUEDE: pasarle
/// http o https a `setURLSchemeHandler` lanza excepción, porque son esquemas que WKWebView
/// maneja nativamente. La salida es un esquema propio con host, que es exactamente lo que
/// hacen Capacitor y Cordova en decenas de miles de apps publicadas.
///
/// El precio de no ser un "secure context" es UNA sola cosa en todo el cliente:
/// `navigator.clipboard` (los botones "Copiar CBU"/"Copiar Alias" del Mercado). Se tapa
/// desde el lado nativo en parche_ios.js. No hay ningún otro uso de API que exija contexto
/// seguro: ni crypto.subtle, ni serviceWorker, ni getUserMedia, ni geolocation.
final class ManejadorRecursos: NSObject, WKURLSchemeHandler {

    /// Carpeta `www` dentro del paquete (la copia exacta de web/dist).
    private let raiz: URL

    /// Tareas vivas. WebKit puede cancelar una tarea mientras se lee el archivo, y
    /// responderle a una tarea ya cancelada hace CRASHEAR el proceso. Se accede siempre
    /// bajo el candado.
    private var vivas = Set<ObjectIdentifier>()
    private let candado = NSLock()

    /// Cola propia: leer 137 MB de recursos no puede bloquear el hilo principal.
    private let cola = DispatchQueue(label: "cc.aoforever.recursos", qos: .userInitiated, attributes: .concurrent)

    override init() {
        // resourceURL y NO bundleURL: en iOS son la misma carpeta, pero en la app de Mac
        // (Mac Catalyst) los recursos viven en AOForever.app/Contents/Resources/. Con
        // bundleURL la Mac buscaria www/ en la raiz del .app, no habria NADA y el juego
        // arrancaria en negro (todo 404).
        let base = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        raiz = base.appendingPathComponent("www", isDirectory: true)
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        candado.lock(); vivas.insert(id); candado.unlock()

        guard let url = task.request.url else {
            terminar(task, id, error: URLError(.badURL))
            return
        }

        // El path llega percent-encoded. El juego tiene nombres heredados del cliente VB6
        // con espacios, "+" y paréntesis ("recursos/graficos/+ 4 polar.png",
        // "recursos/wav/145 .wav", "recursos/graficos/1a (2).png"), así que decodificar
        // NO es opcional.
        var relativo = url.path
        if relativo.hasPrefix("/") { relativo.removeFirst() }
        relativo = relativo.removingPercentEncoding ?? relativo

        // El index vive en www/index.html y las URLs son .../www/…: se saca ese prefijo
        // para no terminar buscando www/www/…
        if relativo.hasPrefix("www/") { relativo = String(relativo.dropFirst(4)) }
        if relativo.isEmpty { relativo = "index.html" }

        let archivo = raiz.appendingPathComponent(relativo)

        // Cinturón contra path traversal: nada fuera de www/, aunque la URL traiga "..".
        guard archivo.standardizedFileURL.path.hasPrefix(raiz.standardizedFileURL.path) else {
            responder404(task, id)
            return
        }

        cola.async { [weak self] in
            guard let self else { return }
            guard let datos = try? Data(contentsOf: archivo, options: .mappedIfSafe) else {
                self.responder404(task, id)
                return
            }
            let mime = Self.mime(de: relativo)

            // RANGO: el <audio> de la pantalla del Mercado (MusicaMercada.wav, ~1,8 MB)
            // pide con Range, y WebKit espera un 206 con Content-Range. Sin esto el audio
            // no arranca o se corta.
            if let rango = task.request.value(forHTTPHeaderField: "Range"),
               let (desde, hasta) = Self.parseRango(rango, total: datos.count) {
                let trozo = datos.subdata(in: desde..<(hasta + 1))
                let cab: [String: String] = [
                    "Content-Type": mime,
                    "Content-Length": String(trozo.count),
                    "Content-Range": "bytes \(desde)-\(hasta)/\(datos.count)",
                    "Accept-Ranges": "bytes",
                    "Access-Control-Allow-Origin": "*",
                ]
                let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: cab)!
                self.entregar(task, id, resp, trozo)
                return
            }

            let cab: [String: String] = [
                "Content-Type": mime,
                "Content-Length": String(datos.count),
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*",
            ]
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: cab)!
            self.entregar(task, id, resp, datos)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        candado.lock(); vivas.remove(id); candado.unlock()
    }

    // MARK: - Entrega segura

    private func sigueViva(_ id: ObjectIdentifier) -> Bool {
        candado.lock(); defer { candado.unlock() }
        return vivas.contains(id)
    }

    private func entregar(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ resp: URLResponse, _ datos: Data) {
        DispatchQueue.main.async {
            guard self.sigueViva(id) else { return }
            task.didReceive(resp)
            task.didReceive(datos)
            task.didFinish()
            self.candado.lock(); self.vivas.remove(id); self.candado.unlock()
        }
    }

    private func terminar(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, error: Error) {
        DispatchQueue.main.async {
            guard self.sigueViva(id) else { return }
            task.didFailWithError(error)
            self.candado.lock(); self.vivas.remove(id); self.candado.unlock()
        }
    }

    /// 404 con cuerpo VACÍO y `text/plain`.
    ///
    /// NUNCA `text/html`: main.ts y preloadAssets.ts descartan toda respuesta cuyo
    /// content-type contenga text/html — así detectan un "404 disfrazado" del hosting. Si
    /// acá se devolviera html, un archivo faltante se vería como un archivo corrupto.
    private func responder404(_ task: WKURLSchemeTask, _ id: ObjectIdentifier) {
        guard let url = task.request.url else { return }
        let resp = HTTPURLResponse(
            url: url, statusCode: 404, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain", "Content-Length": "0"]
        )!
        entregar(task, id, resp, Data())
    }

    // MARK: - MIME y Range

    /// MIME por EXTENSIÓN, nunca adivinado.
    ///
    /// Es la misma tabla que la clase ManejadorAssets de Android y por el mismo motivo: el
    /// juego está lleno de nombres raros heredados del VB6, y adivinar el tipo por el
    /// nombre falla. Para el bundle es fatal: el index emite `<script type="module">`, y
    /// con un MIME que no sea de JavaScript WebKit lo BLOQUEA → pantalla negra.
    static func mime(de ruta: String) -> String {
        switch (ruta as NSString).pathExtension.lowercased() {
        case "js", "mjs":  return "text/javascript"
        case "html", "htm": return "text/html"
        case "css":        return "text/css"
        case "json":       return "application/json"
        case "xml":        return "text/xml"
        case "png":        return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":        return "image/gif"
        case "webp":       return "image/webp"
        case "wav":        return "audio/wav"
        case "mid", "midi": return "audio/midi"
        case "ttf":        return "font/ttf"
        case "otf":        return "font/otf"
        case "woff2":      return "font/woff2"
        // .map (mapas del juego) y .fnt se leen con arrayBuffer()/text(): el MIME no
        // influye. Lo único que importa es que NO sea text/html.
        default:           return "text/plain"
        }
    }

    /// "bytes=0-1023", "bytes=500-" o "bytes=-500". Devuelve el rango cerrado ya acotado.
    static func parseRango(_ header: String, total: Int) -> (Int, Int)? {
        guard total > 0, header.hasPrefix("bytes=") else { return nil }
        let cuerpo = header.dropFirst("bytes=".count)
        let partes = cuerpo.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard partes.count == 2 else { return nil }
        let a = String(partes[0]), b = String(partes[1])

        var desde: Int
        var hasta: Int
        if a.isEmpty {
            // Sufijo: los últimos N bytes.
            guard let n = Int(b), n > 0 else { return nil }
            desde = max(0, total - n)
            hasta = total - 1
        } else {
            guard let d = Int(a) else { return nil }
            desde = d
            hasta = b.isEmpty ? total - 1 : (Int(b) ?? total - 1)
        }
        guard desde >= 0, desde < total else { return nil }
        hasta = min(hasta, total - 1)
        guard hasta >= desde else { return nil }
        return (desde, hasta)
    }
}
