import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Kept alive for the app's lifetime (lib/data/storage.dart).
  private var storageChannel: FlutterMethodChannel?
  /// Kept alive for the app's lifetime (lib/signals/screen_brightness.dart).
  private var brightnessChannel: FlutterMethodChannel?
  private var brightnessEvents: FlutterEventChannel?
  private let brightnessStream = BrightnessStreamHandler()
  /// Kept alive for the app's lifetime (lib/signals/screen_awake.dart).
  private var screenChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    registerBrightnessChannels(engineBridge)
    registerScreenChannel(engineBridge)

    // Downloaded audio can be gigabytes and is re-downloadable from the
    // server, so it must not go into the iCloud backup (decision E35).
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FadenStorage") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "de.faden.app/storage",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path missing", details: nil))
        return
      }
      var url = URL(fileURLWithPath: path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
      }
    }
    storageChannel = channel
  }

  /// While the Faden screen is open the phone must not lock itself between
  /// two probes (decision E85): only the auto-lock is held back.
  private func registerScreenChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FadenScreen") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "de.faden.app/screen",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "keepOn" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    }
    screenChannel = channel
  }

  /// The display brightness switches the night view (decision E54). Only
  /// read, never set: `UIScreen.main.brightness` is the value the user
  /// chose in Control Center or auto-brightness picked.
  private func registerBrightnessChannels(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FadenBrightness") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "de.faden.app/brightness",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Double(UIScreen.main.brightness))
    }
    brightnessChannel = channel

    let events = FlutterEventChannel(
      name: "de.faden.app/brightness/changes",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(brightnessStream)
    brightnessEvents = events
  }
}

/// Sends `UIScreen.main.brightness` (0...1) while Dart listens: once on
/// listen, on every `brightnessDidChangeNotification`, when the app becomes
/// active again, and every 5 s while it is active -- the notification is
/// not documented to fire for auto-brightness, so the poll catches a screen
/// that dims itself in a dark bedroom.
final class BrightnessStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var lastSent: CGFloat?
  private var pollTimer: Timer?
  private var observers: [NSObjectProtocol] = []

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main) {
        [weak self] _ in self?.send()
      },
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        self?.send()
        self?.startPolling()
      },
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in self?.stopPolling()
      },
    ]
    send(force: true)
    if UIApplication.shared.applicationState == .active {
      startPolling()
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    stopPolling()
    sink = nil
    lastSent = nil
    return nil
  }

  private func startPolling() {
    guard pollTimer == nil else { return }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      self?.send()
    }
  }

  private func stopPolling() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  private func send(force: Bool = false) {
    guard let sink = sink else { return }
    let value = UIScreen.main.brightness
    if !force, let last = lastSent, abs(last - value) < 0.005 {
      return
    }
    lastSent = value
    sink(Double(value))
  }
}
