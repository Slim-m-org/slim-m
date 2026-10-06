// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Registers this device for push and keeps the server's foreground guess
/// current.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart';

import 'providers.dart';
import 'push_content_preview_settings.dart';
import 'push_status.dart';

export 'push_status.dart';

/// The native bridge for this device's APNs token. A provider, rather than a
/// field [PushController] constructs itself, so a test can substitute one
/// that does not depend on the test runner actually being iOS.
final apnsTokenChannelProvider = Provider<ApnsTokenChannel>(
  (ref) => ApnsTokenChannel(),
);

/// The bridge for this device's FCM registration token, Android's
/// counterpart to [apnsTokenChannelProvider]. A provider for the same
/// reason: a test can substitute one that does not depend on the test
/// runner actually being Android.
final fcmTokenChannelProvider = Provider<FcmTokenChannel>(
  (ref) => FcmTokenChannel(),
);

/// The seam onto Android's local-notification channel: creating it, and
/// asking for runtime permission to use it. A provider, for the same reason
/// as the two above - a test can substitute one that reports "denied"
/// without a real Android device or plugin channel behind it.
final localNotificationsProvider = Provider<LocalNotifications>(
  (ref) => LocalNotifications(),
);

/// Registers this device's push token and encryption public key, and reports
/// foreground/background transitions once registered.
///
/// Session-driven, exactly like [SessionStore.changes] drives every other
/// controller in this app: a fresh sign-in and a session already restored at
/// launch both need the same retry, so neither is a special case here, only
/// the two moments the session can start being signed in. Only the
/// signed-out/signed-in edge triggers it, not every emission: the server
/// rotates access tokens well inside a live session, and re-running the whole
/// APNs fetch and registration on each routine rotation would be wasted work
/// at best, and at worst two overlapping first registrations racing to tell
/// the server which locally-generated keypair is current, leaving it holding
/// the public half of one the device already discarded. Every step past that
/// is best-effort: a user who denied notifications, or is running the Linux
/// desktop build where there is no push channel at all, must still get a
/// fully working app.
///
/// iOS and Android are both handled here rather than split into two
/// controllers: which one actually runs on a given device is decided by
/// [apnsTokenChannelProvider] and [fcmTokenChannelProvider] each reporting
/// "unsupported" on the platform that is not theirs (see
/// [ApnsTokenChannel] and [FcmTokenChannel]), not by this class asking
/// `Platform.isIOS`/`Platform.isAndroid` itself - which would make every
/// branch here untestable on a machine that is neither.
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

  /// Android's most recently rotated token, when it landed while a
  /// registration was already in flight and so could not be part of it: set
  /// the moment that happens, and consumed by that in-flight attempt's own
  /// completion handler, which starts a follow-up for it. See
  /// [_reregisterAndroid] and [_runRegistering].
  String? _pendingAndroidToken;

  /// Keeps the server's foreground guess from ever crossing its own one-minute
  /// staleness window during a single long-lived foreground session; see
  /// [_reportLifecycle].
  Timer? _foregroundHeartbeat;

  /// [fcmTokenChannelProvider]'s rotation stream, guarded against the getter
  /// itself throwing rather than just the Future it might otherwise return:
  /// on an Android build with no `google-services.json` (see
  /// `android/app/build.gradle.kts`), Firebase never gets a default app to
  /// hand FirebaseMessaging, and asking for its stream throws
  /// `[core/no-app]` synchronously, right here at construction - before
  /// `register()`'s own try/catch machinery is even reachable. Push
  /// degrading is fine; this controller failing to construct at all, and
  /// taking every other provider `main()` reads down with it, is not.
  Stream<String> _fcmTokenRefreshStream() {
    try {
      return _ref.read(fcmTokenChannelProvider).onTokenRefresh;
    } catch (_) {
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

  /// Whether the server currently holds this device's push registration,
  /// regardless of whether Android's notification permission is actually
  /// granted: [PushStatus.registeredNotificationsBlocked] still means the
  /// server has a live token for this device and expects the same lifecycle
  /// reports [PushStatus.registered] does.
  bool get _isRegisteredWithServer =>
      state == PushStatus.registered ||
      state == PushStatus.registeredNotificationsBlocked;

  /// Fetches, or reuses, this device's push keypair and token, and tells the
  /// server about them. A no-op without a session, and every failure past
  /// that point is recorded in [state] rather than thrown, so a push problem
  /// never becomes an app problem.
  ///
  /// Non-reentrant: the session listener, a resume, and an explicit caller
  /// can all ask for this at once, and two concurrent attempts racing to
  /// register a keypair is exactly the failure this exists to close, so a
  /// call that arrives while one is already running shares it rather than
  /// starting a second.
  Future<void> register() {
    return _registering ??= _runRegistering(_registerOnce);
  }

  /// Runs [task] as this controller's one in-flight registration attempt,
  /// then - once it finishes - starts a follow-up for [_pendingAndroidToken]
  /// if a rotation landed while it ran. Every caller that sets
  /// [_registering] routes through here (both [register] and
  /// [_reregisterAndroid]) so that follow-up fires no matter which kind of
  /// attempt it was queued behind.
  ///
  /// Runs entirely synchronously from `task()` returning through to
  /// `_registering` being reassigned to the follow-up, with no `await` in
  /// between: a caller reading `_registering` at any point never sees it
  /// null while a rotated token is still waiting to be sent, which is
  /// exactly the gap a second, uncoordinated registration could otherwise
  /// race into.
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

  /// Asks the iOS channel first. On a real device exactly one of the two ever
  /// reports anything other than "unsupported" (a device is never both iOS and
  /// Android), so an iOS answer that is not a bare "unsupported" is this
  /// device's whole story and the Android channel is never consulted. Only when
  /// iOS is definitively not it - including on Linux desktop, where nothing is
  /// - does the Android channel get to decide the state.
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
      case ApnsRegistrationFailed():
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

  /// Notification permission is requested here, in the foreground app that is
  /// about to register this token, never from `LocalNotifications.show`: that
  /// also runs in FCM's Activity-less background isolate, where asking throws
  /// instead of prompting anyone.
  ///
  /// Registration happens regardless of the answer - a permission granted later
  /// needs a token already on file to do any good - but the answer decides
  /// which of [PushStatus.registered] or
  /// [PushStatus.registeredNotificationsBlocked] this reports, so the settings
  /// screen tells the truth about whether anything will actually show.
  Future<void> _applyAndroidResult(FcmTokenResult result) async {
    switch (result) {
      case FcmUnsupported():
        state = PushStatus.unsupportedPlatform;
      case FcmRegistrationFailed():
        state = PushStatus.registrationFailed;
      case FcmTokenReady(:final token):
        final permitted = await _requestAndroidPermission();
        await _registerWithServer(platform: 'android', token: token);
        if (!permitted && state == PushStatus.registered) {
          state = PushStatus.registeredNotificationsBlocked;
        }
    }
  }

  /// Wraps [LocalNotifications.requestPermission] so an unexpected native
  /// failure degrades to "treat this like a denial" instead of throwing out
  /// of [_applyAndroidResult] - and, past that, out of [register] itself,
  /// which this whole class promises never happens. An error here is not
  /// proof notifications are permitted, so reporting doubt honestly is the
  /// safer of the two guesses.
  Future<bool> _requestAndroidPermission() async {
    try {
      return await _ref.read(localNotificationsProvider).requestPermission();
    } catch (_) {
      return false;
    }
  }

  /// Re-registers with a rotated FCM token without going through the whole
  /// `_registerOnce` dance (there is no channel to re-ask; FCM already
  /// handed us the new token). Shares [_registering] with an ordinary
  /// [register] call for the same reason that guard exists at all: a
  /// rotation landing mid-registration must not race a second `PUT /push`
  /// for this device.
  ///
  /// A rotation landing while an attempt is already in flight is never
  /// dropped: that attempt started before the rotation happened and so
  /// cannot be carrying it, so this queues it in [_pendingAndroidToken]
  /// instead of discarding it. `return _registering ??= ...` looks
  /// equivalent but is not - Dart never evaluates the right-hand side once
  /// the left is already non-null, so the token this call was given
  /// vanishes entirely, leaving the server holding a now-invalid token and
  /// this device dead until something unrelated (a resume, a fresh
  /// sign-in) happens to re-register it.
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

  /// Reports the current lifecycle state immediately after a successful
  /// registration, because Flutter does not replay it to an observer added
  /// earlier and the server treats a foreground report as stale after a minute.
  /// Without that the app can sit freshly registered but never known to be
  /// foreground, so every message pushes a notification to the screen the user
  /// is already looking at.
  ///
  /// [PushContentPreviewController.currentValue] is read fresh on every call,
  /// not cached on this controller: it is the one thing here a person can
  /// change without signing out and back in, so a re-registration triggered
  /// by flipping that setting has to reach the server with the new answer,
  /// not the one this device registered with last.
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
      final current =
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
      unawaited(_reportLifecycle(_stateLabel(current)));
    } catch (_) {
      state = PushStatus.serverError;
    }
  }

  /// On iOS `inactive` is a visible-but-not-focused app: the Control Centre
  /// pulled down, the app switcher, an incoming call banner. Treating it as
  /// background would notify someone who is looking straight at the screen, so
  /// only a genuinely hidden app counts as background.
  static String _stateLabel(AppLifecycleState state) => switch (state) {
    AppLifecycleState.resumed || AppLifecycleState.inactive => 'foreground',
    _ => 'background',
  };

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
    if (_isRegisteredWithServer) {
      unawaited(_reportLifecycle(_stateLabel(state)));
    }
  }

  /// Drops this device's push registration and the key it was sealed to.
  /// Called on sign-out, while the owning session is still valid, and clears
  /// the local key too so the next account signed into this device gets a
  /// fresh one rather than inheriting this account's.
  ///
  /// Neither step is allowed to throw. An unreachable server or a failing key
  /// store must not abort sign-out mid-way and strand the user on the settings
  /// screen with sync already stopped; the server-side registration is cleared
  /// on session revocation anyway.
  ///
  /// Both key stores are cleared, not just the one this build writes to. On
  /// iOS a device that has not registered since upgrading still has the old
  /// copy sitting where an earlier build left it (see
  /// [legacyPushKeyStoreProvider]), and clearing only the new location would
  /// leave the outgoing account's key behind for the next account to inherit.
  Future<void> unregister() async {
    try {
      await _ref.read(apiProvider).unregisterPush();
    } catch (_) {
      // Must not strand the user mid-sign-out; see the doc above.
    }
    final legacy = _ref.read(legacyPushKeyStoreProvider);
    for (final store in [
      _ref.read(pushKeyStoreProvider),
      if (legacy != null) legacy,
    ]) {
      try {
        await store.delete(devicePushKeyHandle);
      } catch (_) {
        // Same reasoning as above.
      }
    }
    _stopForegroundHeartbeat();
    state = PushStatus.notSignedIn;
  }

  /// How often a genuinely foregrounded app re-reports "foreground" on its
  /// own, without waiting for another lifecycle transition. The server
  /// treats a foreground report as stale after a minute (see
  /// [_registerWithServer]'s own comment on why the first report exists at
  /// all); a strictly shorter interval here is what keeps a user who stays
  /// on one screen for minutes at a time from ever crossing that staleness
  /// window and starting to receive pushes for messages already on their
  /// screen.
  static const _foregroundHeartbeatInterval = Duration(seconds: 45);

  void _startForegroundHeartbeat() {
    _foregroundHeartbeat ??= Timer.periodic(_foregroundHeartbeatInterval, (_) {
      unawaited(_reportLifecycle('foreground'));
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
    } catch (_) {
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
