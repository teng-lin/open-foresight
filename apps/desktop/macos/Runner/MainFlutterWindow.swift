import Cocoa
import FlutterMacOS
import Carbon
import ServiceManagement

class MainFlutterWindow: NSWindow {
  private var integration: DesktopIntegration?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    backgroundColor = NSColor(calibratedRed: 0.914, green: 0.933, blue: 0.965, alpha: 1)

    RegisterGeneratedPlugins(registry: flutterViewController)

    isReleasedWhenClosed = false
    integration = DesktopIntegration(window: self, messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

private class DesktopIntegration {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private let activation: FlutterMethodChannel
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var registeredTrigger: String?
  private let signature: OSType = 0x4F465351

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "foresight/desktop", binaryMessenger: messenger)
    activation = FlutterMethodChannel(name: "foresight/window", binaryMessenger: messenger)
    activation.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "activate": self?.activate(); result(nil)
      case "ensureWidth":
        let arguments = call.arguments as? [String: Any]
        guard let width = arguments?["width"] as? NSNumber,
              width.doubleValue.isFinite, width.doubleValue > 0 else {
          result(FlutterError(code: "invalid_width", message: "Expected a positive window width", details: nil))
          return
        }
        self?.ensureWidth(CGFloat(width.doubleValue))
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "shortcut.enable":
          let arguments = call.arguments as? [String: Any]
          try self.registerShortcut(arguments?["trigger"] as? String ?? "CTRL+SHIFT+F")
          result(nil)
        case "shortcut.disable": self.unregisterShortcut(); result(nil)
        case "login.get": result(SMAppService.mainApp.status == .enabled)
        case "login.set":
          let arguments = call.arguments as? [String: Any]
          if arguments?["enabled"] as? Bool == true {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
              throw NSError(domain: "OpenForesight", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Open Foresight in System Settings → General → Login Items."])
            }
          } else { try SMAppService.mainApp.unregister() }
          result(nil)
        case "activate": self.activate(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "macos_integration", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func activate() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func ensureWidth(_ width: CGFloat) {
    guard let window = window, let content = window.contentView else { return }
    let extra = max(0, width - content.bounds.width)
    guard extra > 0 else { return }
    var frame = window.frame
    frame.size.width += extra
    if let screen = window.screen {
      let visible = screen.visibleFrame
      frame.size.width = min(frame.width, max(window.frame.width, visible.width))
      frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
    }
    window.setFrame(frame, display: true, animate: false)
  }

  private func unregisterShortcut() {
    if let key = hotKey { UnregisterEventHotKey(key) }
    hotKey = nil
    registeredTrigger = nil
    if let eventHandler = handler { RemoveEventHandler(eventHandler) }
    handler = nil
  }

  private func registerShortcut(_ trigger: String) throws {
    let parts = trigger.uppercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    let canonical = parts.joined(separator: "+")
    if hotKey != nil && registeredTrigger == canonical { return }
    let keys: [String: UInt32] = ["A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5,
      "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14,
      "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
      "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "O": 31, "U": 32, "I": 34,
      "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46, "SPACE": 49]
    let modifiers: [String: UInt32] = ["CTRL": UInt32(controlKey), "CONTROL": UInt32(controlKey),
      "SHIFT": UInt32(shiftKey), "ALT": UInt32(optionKey), "OPTION": UInt32(optionKey),
      "CMD": UInt32(cmdKey), "COMMAND": UInt32(cmdKey), "SUPER": UInt32(cmdKey), "META": UInt32(cmdKey)]
    guard let last = parts.last, let code = keys[last], parts.count >= 2,
          parts.dropLast().allSatisfy({ modifiers[$0] != nil }) else {
      throw NSError(domain: "OpenForesight", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose modifiers plus one supported letter, digit, or Space."])
    }
    let flags = parts.dropLast().reduce(UInt32(0)) { $0 | modifiers[$1]! }
    var candidate: EventHotKeyRef?
    let identifier = EventHotKeyID(signature: signature, id: 1)
    // Validate/register first so an unavailable replacement keeps the old key.
    let registration = RegisterEventHotKey(code, flags, identifier, GetApplicationEventTarget(), 0, &candidate)
    guard registration == noErr else {
      throw NSError(domain: "OpenForesight", code: Int(registration), userInfo: [NSLocalizedDescriptionKey: "The global shortcut could not be registered. It may already be in use."])
    }
    unregisterShortcut()
    hotKey = candidate
    registeredTrigger = canonical
    var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
      guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
      let object = Unmanaged<DesktopIntegration>.fromOpaque(context).takeUnretainedValue()
      var identifier = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &identifier)
      guard identifier.signature == object.signature else { return OSStatus(eventNotHandledErr) }
      object.activate()
      object.channel.invokeMethod("quick-meeting", arguments: nil)
      return noErr
    }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
    if installed != noErr {
      unregisterShortcut()
      throw NSError(domain: "OpenForesight", code: Int(installed), userInfo: [NSLocalizedDescriptionKey: "Could not install the shortcut handler."])
    }
  }

  deinit { unregisterShortcut() }
}
