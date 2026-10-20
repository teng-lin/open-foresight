import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the last window ends the desktop connection. The service then
    // finalizes capture and releases its helper and model workers.
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    mainFlutterWindow?.deminiaturize(nil)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == "open-foresight" && url.host == "login-in-progress" {
      CalendarAuthBridge.receive(url.absoluteString)
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

// Retain early Launch Services returns until Dart installs its receiver. Never
// log the URL: it carries a short-lived authorization code.
enum CalendarAuthBridge {
  private static var channel: FlutterMethodChannel?
  private static var ready = false
  private static var pending: [String] = []

  static func install(_ messenger: FlutterBinaryMessenger) {
    let newChannel = FlutterMethodChannel(name: "foresight/calendar-auth", binaryMessenger: messenger)
    channel = newChannel
    newChannel.setMethodCallHandler { call, result in
      guard call.method == "ready" else { result(FlutterMethodNotImplemented); return }
      ready = true
      let queued = pending
      pending.removeAll()
      result(queued)
    }
  }

  static func receive(_ url: String) {
    guard url.utf8.count <= 16384 else { return }
    if ready { channel?.invokeMethod("open-url", arguments: url) }
    else if pending.count < 4 { pending.append(url) }
  }
}
