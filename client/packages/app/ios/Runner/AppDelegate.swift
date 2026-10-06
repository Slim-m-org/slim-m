// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Shared with the Dart side; see `packages/platform/lib/src/apns_token_channel.dart`.
  private static let pushChannelName = "top.npcserver.slimm/push"

  /// Deliberately its own channel rather than a second method on
  /// `pushChannelName`: Dart's `setMethodCallHandler` replaces rather than
  /// adds, so two Dart objects listening to one channel name would silently
  /// leave the first one deaf. See
  /// `packages/platform/lib/src/notification_tap_channel.dart`.
  private static let tapChannelName = "top.npcserver.slimm/push_tap"

  /// CallKit's answer and end events, held until Dart takes them; see
  /// `packages/platform/lib/src/callkit_incoming_channel.dart`.
  private static let callKitChannelName = "top.npcserver.slimm/callkit_incoming"

  /// Full screen call video asking to rotate; see
  /// `packages/platform/lib/src/orientation_channel.dart` and decision 0058.
  private static let orientationChannelName = "top.npcserver.slimm/orientation"

  /// Off until Dart's full screen call video asks, so the shell launches and
  /// stays portrait whatever the plist's landscape ceiling allows.
  private static var landscapeAllowed = false

  private var orientationChannel: FlutterMethodChannel?
  private var pushChannel: FlutterMethodChannel?
  private var callKitChannel: FlutterMethodChannel?
  private var pendingCallKitEvents: [[String: String]] = []
  private var dartTakesCallKitEvents = false
  private var tapChannel: FlutterMethodChannel?

  // A tap is what launches the app from a killed state, so it routinely
  // happens before Dart exists to be told about it. Held here until Dart
  // asks, exactly as the device token above is.
  private var pendingTapChannelId: String?
  private var notificationTapObserver: NotificationTapObserver?
  private var broadcastChannel: FlutterMethodChannel?
  private var clipboardImageChannel: FlutterMethodChannel?
  private var appLockWindowChannel: FlutterMethodChannel?
  private let voiceCallChannel = VoiceCallChannel()
  private var voipRegistrar: VoipPushRegistrar?
  private var cachedVoipTokenHex: String?

  // The token or a registration failure can each arrive before Dart has asked
  // for it (a fast relaunch) or long after (the user takes a while to decide
  // on the permission prompt). Caching whichever lands first, and answering
  // "getToken"/"getRegistrationError" from the cache, means neither ordering
  // loses the result.
  private var cachedTokenHex: String?
  private var cachedError: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    requestPushAuthorization(application)
    startVoipRegistration()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    AppDelegate.landscapeAllowed ? .allButUpsideDown : .portrait
  }

  private func handleOrientationCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "allowLandscape" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let allowed = call.arguments as? Bool ?? false
    AppDelegate.landscapeAllowed = allowed
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if #available(iOS 16.0, *) {
      for scene in scenes {
        for window in scene.windows {
          window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if !allowed {
          scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
      }
    } else {
      if !allowed {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      }
      UIViewController.attemptRotationToDeviceOrientation()
    }
    result(true)
  }

  /// Constructed during launch, before the first run loop turn: a VoIP push that wakes a
  /// killed app is delivered only to a registry that exists by then, and an unreported one
  /// terminates the app.
  private func startVoipRegistration() {
    let registrar = VoipPushRegistrar()
    registrar.onToken = { [weak self] hex in
      self?.cachedVoipTokenHex = hex
      self?.pushChannel?.invokeMethod("onVoipToken", arguments: hex)
    }
    registrar.onCallEvent = { [weak self] event in self?.deliverCallKitEvent(event) }
    voipRegistrar = registrar
  }

  /// An answer can land before Dart exists to hear it, so events are held until
  /// Dart asks and sent live afterwards, never both.
  private func deliverCallKitEvent(_ event: CallKitCallEvent) {
    guard dartTakesCallKitEvents else {
      pendingCallKitEvents.append(event.wire)
      return
    }
    callKitChannel?.invokeMethod("onCallKitEvent", arguments: event.wire)
  }

  private func handleCallKitCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takePending":
      dartTakesCallKitEvents = true
      let pending = pendingCallKitEvents
      pendingCallKitEvents = []
      result(pending)
    case "endCall":
      if let args = call.arguments as? [String: Any],
        let raw = args["id"] as? String, let id = UUID(uuidString: raw)
      {
        voipRegistrar?.endCall(id)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: AppDelegate.pushChannelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handlePushCall(call, result: result)
    }
    pushChannel = channel

    let orientation = FlutterMethodChannel(
      name: AppDelegate.orientationChannelName, binaryMessenger: messenger)
    orientation.setMethodCallHandler { [weak self] call, result in
      self?.handleOrientationCall(call, result: result)
    }
    orientationChannel = orientation

    let tap = FlutterMethodChannel(name: AppDelegate.tapChannelName, binaryMessenger: messenger)
    tap.setMethodCallHandler { [weak self] call, result in
      self?.handleTapCall(call, result: result)
    }
    tapChannel = tap

    let callKit = FlutterMethodChannel(
      name: AppDelegate.callKitChannelName, binaryMessenger: messenger)
    callKit.setMethodCallHandler { [weak self] call, result in
      self?.handleCallKitCall(call, result: result)
    }
    callKitChannel = callKit

    let broadcast = FlutterMethodChannel(name: BroadcastChannel.name, binaryMessenger: messenger)
    broadcast.setMethodCallHandler { call, result in
      BroadcastChannel.handle(call, result: result)
    }
    broadcastChannel = broadcast

    let appLockWindow = FlutterMethodChannel(
      name: AppLockWindowChannel.name, binaryMessenger: messenger)
    appLockWindow.setMethodCallHandler { call, result in
      AppLockWindowChannel.handle(call, result: result)
    }
    appLockWindowChannel = appLockWindow

    let clipboardImage = FlutterMethodChannel(
      name: ClipboardImagePlugin.name, binaryMessenger: messenger)
    clipboardImage.setMethodCallHandler { call, result in
      ClipboardImagePlugin.handle(call, result: result)
    }
    clipboardImageChannel = clipboardImage
    // See ClipboardPasteBridge.m: this is the callback its swizzled `paste:`
    // hands an image to, from inside iOS's own dispatch of that action.
    ClipboardImagePlugin.editMenuPasteSwizzleInstalled = SlimmInstallClipboardPasteBridge {
      [weak self] pngData in
      self?.clipboardImageChannel?.invokeMethod("pastedImage", arguments: pngData)
    }

    voiceCallChannel.attach(to: messenger)
    installNotificationTapObserver()
  }

  /// Chains a tap observer in front of whatever already holds the notification
  /// delegate, after plugin registration so that whoever claimed it is
  /// captured and kept.
  ///
  /// Chained rather than overridden: `FlutterAppDelegate` implements this
  /// callback but declares it in no public header, so Swift cannot see it to
  /// override it and cannot reach `super` to forward it either. Shadowing it
  /// would silently drop the plugin fan-out that firebase_messaging's own
  /// notification handling rides on. `UNUserNotificationCenterDelegate` is
  /// ordinary public API, so a chain needs none of that.
  private func installNotificationTapObserver() {
    let center = UNUserNotificationCenter.current()
    let observer = NotificationTapObserver(next: center.delegate) { [weak self] channelId in
      self?.deliverTap(channelId)
    }
    // The delegate property is weak, so this reference is what keeps the
    // observer alive.
    notificationTapObserver = observer
    center.delegate = observer
  }

  /// Held as well as sent: on a cold launch the engine exists before Dart has
  /// installed its handler, so the invoke alone would be dropped.
  private func deliverTap(_ channelId: String) {
    pendingTapChannelId = channelId
    tapChannel?.invokeMethod("onNotificationTap", arguments: channelId)
  }

  private func handlePushCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getToken":
      result(cachedTokenHex)
    case "getRegistrationError":
      result(cachedError)
    case "getVoipToken":
      result(cachedVoipTokenHex)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Answers with the channel a tap is waiting to open, and forgets it in the
  /// same breath. Clearing on read is what stops one tap reopening its
  /// channel again on every later launch, which would override wherever the
  /// user had navigated since.
  private func handleTapCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takeInitialTap":
      let pending = pendingTapChannelId
      pendingTapChannelId = nil
      result(pending)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPushAuthorization(_ application: UIApplication) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
      // A device token is worth having even if the user declines the alert:
      // the relay still needs it to seal envelopes, and a later notification
      // service extension can act on a silent push without alert permission.
      DispatchQueue.main.async {
        application.registerForRemoteNotifications()
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // Data's own string conversion is redacted on modern iOS (something like
    // "32 bytes"), so the hex has to be built by hand, byte by byte.
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    cachedTokenHex = hex
    cachedError = nil
    pushChannel?.invokeMethod("onToken", arguments: hex)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    let message = error.localizedDescription
    cachedError = message
    pushChannel?.invokeMethod("onRegistrationError", arguments: message)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}
