import AppKit
import ApplicationServices

/// One application/accessibility bootstrap for all in-process native fixtures.
/// All fixtures share NSApplication and its accessibility bridge.
@MainActor enum NativeTestApplication {
    static let shared: NSApplication = {
        let app = NSApplication.shared
        app.finishLaunching()
        // This bridge queries only objects in this test process.
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }()
}
