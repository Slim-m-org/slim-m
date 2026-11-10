// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Registers this device for push and keeps the server's foreground guess
/// current.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart';

import '../../providers/providers.dart';
import 'push_content_preview_settings.dart';
import 'push_key_cleanup.dart';
import 'push_status.dart';

import 'push_channel_providers.dart';

export 'push_channel_providers.dart';
export 'push_status.dart';

/// Registers this device's push token and encryption public key, and reports
/// foreground/background transitions once registered.
///
/// Only the signed-out/signed-in edge of [SessionStore.changes] triggers
/// registration, not every emission: access tokens rotate inside a live
/// session, and two overlapping first registrations could leave the server
/// holding the public half of a keypair the device already discarded. Every
/// step past that is best-effort, so a denied permission or the Linux desktop
/// build (no push channel) still gets a working app.
///
/// iOS and Android share this class: [apnsTokenChannelProvider] and
/// [fcmTokenChannelProvider] each report "unsupported" off their own platform,
/// so no branch here asks `Platform.isIOS`, which would be untestable.
class PushController extends StateNotifier<PushStatus>
    with WidgetsBindingObserver {
  PushController(this._ref) : super(PushStatus.notSignedIn) {
    final session = _ref.read(sessionProvider);
    // Subscribe before reading the current value, so a change landing between
    // the two is never missed.
    _sessionSubscription = session.changes.listen((tokens) {
      final signedIn = tokens != null;
      if (signedIn == _lastSignedIn) return;
      _lastSignedIn = signedIn;
      if (signedIn) {
        unawaited(register());
      } else {
        _stopForegroundHeartbeat();
        state = PushStatus.notSignedIn;
      }
    });
    // Kept for this controller's whole life, not just while registered: a
    // failed attempt still needs the next resume to retry on.
    WidgetsBinding.instance.addObserver(this);
    _hasBeenResumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _lastSignedIn = session.isSignedIn;
    if (_lastSignedIn) unawaited(register());

    _voipRefreshSubscription = _ref
        .read(apnsTokenChannelProvider)
        .onVoipToken
        .listen((_) => _reregisterAfterVoipToken());

    // FcmTokenChannel.onTokenRefresh is permanently empty off Android, so this
    // costs nothing on iOS or desktop and needs no platform check of its own.
    _fcmRefreshSubscription = _fcmTokenRefreshStream().listen((token) {
      if (_ref.read(sessionProvider).isSignedIn) {
        unawaited(_reregisterAndroid(token));
      }
    });
  }

  final Ref _ref;
  StreamSubscription<String>? _voipRefreshSubscription;
  late final StreamSubscription<TokenPair?> _sessionSubscription;
  late final StreamSubscription<String> _fcmRefreshSubscription;
  bool _lastSignedIn = false;
  Future<void>? _registering;

  /// Android's rotated token that landed while a registration was in flight;
  /// the in-flight attempt's completion starts a follow-up for it, see
  /// [_reregisterAndroid] and [_runRegistering].
  String? _pendingAndroidToken;

  /// Keeps the server's foreground guess inside its one-minute staleness
  /// window; see [_reportLifecycle].
  Timer? _foregroundHeartbeat;

  /// [fcmTokenChannelProvider]'s rotation stream, guarded against the getter
  /// itself throwing: with no `google-services.json` Firebase has no default
  /// app and the stream throws synchronously at construction, which must not
  /// take down every provider `main()` reads.
  Stream<String> _fcmTokenRefreshStream() {
    try {
      return _ref.read(fcmTokenChannelProvider).onTokenRefresh;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.push,
        'Could not listen for push token changes',
        error,
        stack,
      );
      return const Stream.empty();
    }
  }

  /// A VoIP token that lands after registration started is not in that PUT, so
  /// registration runs again once any attempt in flight finishes.
  void _reregisterAfterVoipToken() {
    if (!_ref.read(sessionProvider).isSignedIn) return;
    final inFlight = _registering;
    if (inFlight == null) {
      unawaited(register());
      return;
    }
    unawaited(inFlight.whenComplete(() => unawaited(register())));
  }

  /// Whether the server holds a live token for this device, including
  /// [PushStatus.registeredNotificationsBlocked], and expects lifecycle reports.
  bool get _isRegisteredWithServer =>
      state == PushStatus.registered ||
      state == PushStatus.registeredNotificationsBlocked;

  /// Fetches, or reuses, this device's push keypair and token, and tells the
  /// server about them. A no-op without a session; every later failure lands in
  /// [state] rather than being thrown.
  ///
  /// Non-reentrant: a call that arrives mid-attempt shares it, since two
  /// concurrent attempts racing to register a keypair is what this prevents.
  Future<void> register() {
    return _registering ??= _runRegistering(_registerOnce);
  }

  /// Runs [task] as the one in-flight registration attempt, then starts a
  /// follow-up for [_pendingAndroidToken] if a rotation landed meanwhile.
  ///
  /// Synchronous from `task()` returning to `_registering` being reassigned, so
  /// a reader never sees it null while a rotated token is still waiting.
  Future<void> _runRegistering(Future<void> Function() task) {
    final future = task().whenComplete(() {
      _registering = null;
      final pendingToken = _pendingAndroidToken;
      if (pendingToken != null) {
        _pendingAndroidToken = null;
        unawaited(
          _runRegistering(
            () => _registerWithServer(platform: 'android', token: pendingToken),
          ),
        );
      }
    });
    _registering = future;
    return future;
  }

  /// Asks the iOS channel first; only a bare "unsupported" falls through to the
  /// Android channel, which also covers Linux desktop where nothing answers.
  Future<void> _registerOnce() async {
    if (!_ref.read(sessionProvider).isSignedIn) {
      state = PushStatus.notSignedIn;
      return;
    }

    final iosResult = await _ref.read(apnsTokenChannelProvider).fetch();
    if (iosResult is! ApnsUnsupported) {
      await _applyIosResult(iosResult);
      return;
    }

    final androidResult = await _ref.read(fcmTokenChannelProvider).fetch();
    await _applyAndroidResult(androidResult);
  }

  Future<void> _applyIosResult(ApnsTokenResult result) async {
    switch (result) {
      case ApnsUnsupported():
        state = PushStatus.unsupportedPlatform;
      case ApnsTokenPending():
        state = PushStatus.noTokenYet;
      case ApnsRegistrationFailed(:final reason):
        AppLog.warning(
          LogTag.push,
          'Could not register this device for push notifications',
          context: {'platform': 'ios', 'reason': reason},
        );
        state = PushStatus.registrationFailed;
      case ApnsTokenReady(:final token):
        final voipToken = await _ref
            .read(apnsTokenChannelProvider)
            .cachedVoipToken();
        await _registerWithServer(
          platform: 'ios',
          token: token,
          voipToken: voipToken,
        );
    }
  }

  /// Notification permission is requested here, never from
  /// `LocalNotifications.show`, which also runs in FCM's Activity-less isolate
  /// where asking throws.
  ///
  /// Registration happens regardless of the answer, since a permission granted
  /// later needs a token on file; the answer only picks which of
  /// [PushStatus.registered] or [PushStatus.registeredNotificationsBlocked]
  /// this reports.
  Future<void> _applyAndroidResult(FcmTokenResult result) async {
    switch (result) {
      case FcmUnsupported():
        state = PushStatus.unsupportedPlatform;
      case FcmRegistrationFailed(:final reason):
        AppLog.warning(
          LogTag.push,
          'Could not register this device for push notifications',
          context: {'platform': 'android', 'reason': reason},
        );
        state = PushStatus.registrationFailed;
      case FcmTokenReady(:final token):
        final permitted = await _requestAndroidPermission();
        await _registerWithServer(platform: 'android', token: token);
        if (!permitted && state == PushStatus.registered) {
          state = PushStatus.registeredNotificationsBlocked;
        }
    }
  }

  /// Wraps [LocalNotifications.requestPermission] so a native failure reads as
  /// a denial rather than throwing out of [register].
  Future<bool> _requestAndroidPermission() async {
    try {
      return await _ref.read(localNotificationsProvider).requestPermission();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.push,
        'Could not ask for the notification permission',
        error,
        stack,
      );
      return false;
    }
  }

  /// Re-registers with a rotated FCM token, sharing [_registering] with
  /// [register] so a rotation cannot race a second `PUT /push`.
  ///
  /// A rotation landing mid-attempt is queued in [_pendingAndroidToken], not
  /// dropped: `return _registering ??= ...` would never evaluate the new token.
  Future<void> _reregisterAndroid(String token) {
    final inFlight = _registering;
    if (inFlight != null) {
      _pendingAndroidToken = token;
      return inFlight;
    }
    return _runRegistering(
      () => _registerWithServer(platform: 'android', token: token),
    );
  }

  /// Reports the lifecycle state right after registering, since Flutter does
  /// not replay it to an earlier observer and the server treats a foreground
  /// report as stale after a minute.
  ///
  /// The content-preview setting is read fresh each call, because flipping it
  /// re-registers and must reach the server with the new answer.
  Future<void> _registerWithServer({
    required String platform,
    required String token,
    String? voipToken,
  }) async {
    try {
      final publicKey = await DevicePushKeys(
        _ref.read(pushKeyStoreProvider),
        legacy: _ref.read(legacyPushKeyStoreProvider),
      ).publicKeyBase64();
      final preview = _ref.read(pushContentPreviewSettingsProvider.notifier);
      final includeContent = await preview.pendingChoice();

      await _ref
          .read(apiProvider)
          .registerPush(
            platform: platform,
            pushToken: token,
            voipPushToken: voipToken,
            pushPublicKey: publicKey,
            includeContent: includeContent,
          );
      if (includeContent != null) unawaited(preview.markSent());
      state = PushStatus.registered;
      unawaited(_reportLifecycle(_currentLabel()));
    } catch (error, stack) {
      reportFailure(
        LogTag.push,
        'register this device for push notifications',
        error,
        stack,
      );
      state = PushStatus.serverError;
    }
  }

  /// Whether this process has ever been resumed. A process woken in the
  /// background (a call ring, a silent push) is never resumed, and its
  /// `inactive` or missing state must not read as a visible app.
  bool _hasBeenResumed = false;

  String? _lastReportedLabel;

  String _currentLabel() => _stateLabel(WidgetsBinding.instance.lifecycleState);

  /// On iOS `inactive` is a visible-but-not-focused app: the Control Centre
  /// pulled down, the app switcher, an incoming call banner. Treating it as
  /// background would notify someone who is looking straight at the screen, so
  /// only a genuinely hidden app counts as background - but only once the app
  /// has actually been in front of the user during this process.
  String _stateLabel(AppLifecycleState? state) {
    if (state == AppLifecycleState.resumed) _hasBeenResumed = true;
    return switch (state) {
      AppLifecycleState.resumed => 'foreground',
      AppLifecycleState.inactive when _hasBeenResumed => 'foreground',
      _ => 'background',
    };
  }

  /// A resume retries registration when this device is not registered yet. A
  /// denied permission, a token that had not arrived, or a server that was
  /// briefly unreachable all self-heal the same way: try again the next time
  /// the user opens the app, rather than staying silent until the next full
  /// sign-in.
  ///
  /// Note `this.state` is the push status while the bare `state` parameter is
  /// the lifecycle transition being reported.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        this.state != PushStatus.registered) {
      unawaited(register());
    }
    final label = _stateLabel(state);
    // An alt-tab flips focus without changing the label; the heartbeat keeps a foreground report fresh.
    if (_isRegisteredWithServer && label != _lastReportedLabel) {
      unawaited(_reportLifecycle(label));
    }
  }

  /// Drops this device's push registration and the key it was sealed to, on
  /// sign-out while the session is still valid.
  ///
  /// Neither step may throw, or an unreachable server would strand sign-out
  /// midway; the server clears the registration on session revocation anyway.
  /// Both key stores are cleared, since an iOS device that has not registered
  /// since upgrading still holds the old copy (see [legacyPushKeyStoreProvider]).
  Future<void> unregister() async {
    try {
      await _ref.read(apiProvider).unregisterPush();
    } catch (error, stack) {
      reportFailure(
        LogTag.push,
        'unregister this device from push notifications',
        error,
        stack,
      );
      // Must not strand the user mid-sign-out; see the doc above.
    }
    await deleteDevicePushKeys(_ref);
    _stopForegroundHeartbeat();
    state = PushStatus.notSignedIn;
  }

  /// How often a foregrounded app re-reports "foreground" without a lifecycle
  /// transition; kept under the server's one-minute staleness window.
  static const _foregroundHeartbeatInterval = Duration(seconds: 45);

  void _startForegroundHeartbeat() {
    _foregroundHeartbeat ??= Timer.periodic(_foregroundHeartbeatInterval, (_) {
      unawaited(_reportLifecycle(_currentLabel()));
    });
  }

  void _stopForegroundHeartbeat() {
    _foregroundHeartbeat?.cancel();
    _foregroundHeartbeat = null;
  }

  Future<void> _reportLifecycle(String lifecycleLabel) async {
    if (lifecycleLabel == 'foreground') {
      _startForegroundHeartbeat();
    } else {
      _stopForegroundHeartbeat();
    }
    try {
      await _ref.read(apiProvider).reportPushLifecycle(state: lifecycleLabel);
      _lastReportedLabel = lifecycleLabel;
    } catch (error, stack) {
      reportFailure(
        LogTag.push,
        'tell the server whether the app is in the foreground',
        error,
        stack,
      );
      // A dropped lifecycle ping just leaves the server's guess briefly
      // stale; never a reason to surface an error to the user.
    }
  }

  @override
  void dispose() {
    unawaited(_sessionSubscription.cancel());
    unawaited(_fcmRefreshSubscription.cancel());
    unawaited(_voipRefreshSubscription?.cancel());
    _stopForegroundHeartbeat();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final pushControllerProvider =
    StateNotifierProvider<PushController, PushStatus>(
      (ref) => PushController(ref),
    );
