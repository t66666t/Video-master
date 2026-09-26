import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let imeChannelName = "com.example.video_player_app/ime_gate"
  private var textInputActive = false
  private var keyMonitor: Any?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: imeChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "setTextInputActive" {
        self?.setTextInputActive((call.arguments as? Bool) ?? false)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
      [weak self] event in
      guard let self = self, !self.textInputActive else { return event }
      self.suppressIme()
      return event
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reapplyImeGate),
      name: NSWindow.didBecomeKeyNotification,
      object: self
    )
    setTextInputActive(false)

    super.awakeFromNib()
  }

  @objc private func reapplyImeGate() {
    setTextInputActive(textInputActive)
  }

  private func setTextInputActive(_ active: Bool) {
    textInputActive = active
    if active {
      NSTextInputContext.current?.activate()
      contentViewController?.view.inputContext?.activate()
    } else {
      suppressIme()
    }
  }

  /// Letter keys must not enter marked text unless a text field is editing.
  /// Flutter's text client is a descendant of the Flutter view; move key
  /// focus back to that view so shortcuts stay raw in either input mode.
  private func suppressIme() {
    NSTextInputContext.current?.discardMarkedText()
    guard let flutterView = contentViewController?.view else { return }
    if let responder = firstResponder as? NSView,
       responder !== flutterView,
       responder.isDescendant(of: flutterView) {
      makeFirstResponder(flutterView)
    }
    flutterView.inputContext?.discardMarkedText()
    flutterView.inputContext?.deactivate()
  }
}
