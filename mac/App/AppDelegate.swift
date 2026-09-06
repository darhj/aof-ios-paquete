import UIKit
import AVFoundation

/// Arranque de la app. Sin storyboard y sin escenas: una sola ventana con el juego.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // AUDIO. Sin esto el juego queda MUDO con el interruptor de silencio del iPhone
        // puesto, que es como la mayoría de la gente lleva el teléfono. La categoría
        // .playback dice "esto es contenido, no un sonido de interfaz" y suena igual.
        // .mixWithOthers para no cortarle la música al que está escuchando algo.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Si falla, el juego anda igual: se pierde el sonido con el silencio activado.
            NSLog("AOForever: no se pudo configurar el audio (%@)", error.localizedDescription)
        }

        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = .black
        w.rootViewController = JuegoViewController()
        w.makeKeyAndVisible()
        window = w

        #if targetEnvironment(macCatalyst)
        // APP DE MAC (Mac Catalyst): misma app, en una ventana. Este bloque NO existe en
        // el binario de iPhone (se compila solo para Mac).
        //  - Tamano minimo: por debajo de esto la interfaz de escritorio del juego (la
        //    misma que la web) queda inutilizable.
        //  - Sin barra de titulo: el juego ocupa la ventana entera, como en el navegador
        //    a pantalla completa. La ventana se sigue moviendo/cerrando con las teclas y
        //    los bordes.
        if let escena = w.windowScene {
            escena.sizeRestrictions?.minimumSize = CGSize(width: 960, height: 640)
            escena.titlebar?.titleVisibility = .hidden
            escena.titlebar?.toolbar = nil
        }
        #endif
        return true
    }
}
