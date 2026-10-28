import Cocoa
import SwiftUI

// Render settings tabs with fixture data to PNGs. No server, board, Calendar or Mail access.
@main struct SettingsPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = SettingsStore()
        store.version = "2.1.0 (3613ce9)"
        store.loginItem = true
        store.awakeSupported = true
        store.awakeReady = true
        store.awakeCommand = true
        store.updateText = String(format: L("Up to date (%@)"), "3613ce9") + "\n" + String(format: L("Last checked %@"), "Oct 28, 11:13")
        let views: [(String, AnyView)] = [("general", AnyView(GeneralTab(store: store)))]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (name, view) in views {
                let size = SettingsWindowController.size
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let theme = appearance == .darkAqua ? "dark" : "light"
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("\(APP_LANGUAGE)-\(theme)-\(name).png"))
                window.contentView = nil
            }
        }
    }
}
