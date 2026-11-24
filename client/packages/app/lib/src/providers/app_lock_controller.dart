// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the app-lock screen should be covering slim-m right now.
///
/// Session-driven the same way `PushController` is: only the signed-out edge
/// matters, since signing out already means typing a password again, which
/// makes another biometric prompt on top of it redundant rather than safer.
///
/// Lifecycle-driven for the resume prompt: a phone locked for longer than
/// [lockGraceDuration] re-locks slim-m on its next resume, while a brief trip
/// to the share sheet or the camera and straight back does not - the grace
/// window is what keeps this from being a Face ID prompt on every app
/// switch, which is not what "require Face ID to open slim-m" was asking
/// for.
///
/// One per process in the app, shared by every account's container (see
/// `createAccountHost`), so switching to an account that was not on screen
/// yet, or following a link into one, meets the same lock state.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import 'app_lock_preference.dart';
import 'providers.dart';

/// The seam onto `BiometricAuthChannel`. A provider, like
/// `apnsTokenChannelProvider`, so a test can substitute a fake that needs no
/// real biometric hardware or platform channel behind it.
final biometricAuthChannelProvider = Provider<BiometricAuthChannel>(
  (ref) => BiometricAuthChannel(),
);

/// What the lock reads from the app around it: one account's container for a
/// lone controller, every account's for the process-wide one.
class AppLockHost {
  const AppLockHost({
    required this.enabled,
    required this.signedIn,
    required this.signedInChanges,
    required this.channel,
    required this.disable,
  });

  final bool Function() enabled;
  final bool Function() signedIn;
  final Stream<bool> signedInChanges;
  final BiometricAuthChannel Function() channel;
  final Future<void> Function() disable;

  /// A host over one container's own session and preference.
  factory AppLockHost.forRef(Ref ref) => AppLockHost(
    enabled: () => ref.read(appLockPreferenceProvider),
    signedIn: () => ref.read(sessionProvider).isSignedIn,
    signedInChanges: ref
        .read(sessionProvider)
        .changes
        .map((tokens) => tokens != null),
    channel: () => ref.read(biometricAuthChannelProvider),
    disable: () => ref.read(appLockPreferenceProvider.notifier).set(false),
  );
}

class AppLockController extends StateNotifier<bool>
    with WidgetsBindingObserver {
  AppLockController(this._host, {bool shared = false})
    : _shared = shared,
      super(false) {
    WidgetsBinding.instance.addObserver(this);
    _signedInSubscription = _host.signedInChanges.listen((signedIn) {
      // A real sign-out already means typing a password again; nothing left to lock.
      if (!signedIn) state = false;
    });
  }

  /// The one controller for a whole process, which a container's disposal must not end.
  AppLockController.shared(AppLockHost host) : this(host, shared: true);

  final AppLockHost _host;
  bool _shared;
  late final StreamSubscription<bool> _signedInSubscription;
  DateTime? _backgroundedAt;

  /// How long slim-m can sit backgrounded before its next resume asks for
  /// Face ID/a fingerprint again.
  static const lockGraceDuration = Duration(seconds: 30);

  bool get _enabled => _host.enabled();
  bool get _signedIn => _host.signedIn();

  /// Arms the lock once, right after bootstrap's own preference and session
  /// restores land, so the first frame after the splash already shows the
  /// unlock screen instead of a frame of the real app first. Every later
  /// lock comes from [didChangeAppLifecycleState] instead.
  void armOnLaunch() {
    if (_enabled && _signedIn) state = true;
  }

  /// Note `state` is the lifecycle transition being reported here, while
  /// `this.state` is this controller's own locked/unlocked bool - the same
  /// split `PushController.didChangeAppLifecycleState` documents for the
  /// identical shadowing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Matches PushController's own iOS `inactive` reasoning: a visible-but-unfocused app is not backgrounded.
    final backgrounded =
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive;
    if (backgrounded) {
      markAway();
    } else if (state == AppLifecycleState.resumed) {
      markBack();
    }
  }

  /// The person stepped away without the window leaving the screen: a locked
  /// Windows session or a sleeping machine. Starts the same grace window a
  /// hidden window does.
  void markAway() {
    if (!_enabled || !_signedIn) return;
    _backgroundedAt ??= clock.now();
  }

  /// The person is back; locks when they were away longer than [lockGraceDuration].
  void markBack() {
    if (!_enabled || !_signedIn) return;
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since != null && clock.now().difference(since) >= lockGraceDuration) {
      state = true;
    }
  }

  /// Swallows system back while locked, so it cannot pop the routed page
  /// beneath the lock screen.
  ///
  /// Registered before the `Router`'s own back dispatcher (this exists from
  /// bootstrap, the router mounts later), and observers are asked in
  /// registration order until one answers true.
  @override
  Future<bool> didPopRoute() async => state;

  /// Asks the platform to confirm the device owner. Returns whether slim-m
  /// is unlocked afterward - true on a real success, and also true on the
  /// one outcome this must never trap someone behind: a device that reports
  /// it cannot check an owner at all any more (biometrics unenrolled, the
  /// passcode cleared) after the setting was turned on. That case also turns the
  /// preference back off, so the settings row stops claiming a protection this
  /// device can no longer provide. An error while asking is not that case: it
  /// stays locked and the user can retry.
  Future<bool> unlock({String reason = 'Unlock slim-m'}) async {
    final channel = _host.channel();
    switch (await channel.checkSupport()) {
      case BiometricSupport.unsupported:
        await _giveUpAndUnlock();
        return true;
      case BiometricSupport.error:
        return false;
      case BiometricSupport.supported:
        break;
    }
    switch (await channel.authenticate(reason)) {
      case BiometricAuthResult.success:
        state = false;
        return true;
      case BiometricAuthResult.unavailable:
        await _giveUpAndUnlock();
        return true;
      case BiometricAuthResult.failure:
        return false;
    }
  }

  Future<void> _giveUpAndUnlock() async {
    await _host.disable();
    state = false;
  }

  @override
  void dispose() {
    if (_shared) return;
    unawaited(_signedInSubscription.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Ends a [AppLockController.shared] controller, which [dispose] leaves running.
  void closeShared() {
    _shared = false;
    dispose();
  }
}

final appLockControllerProvider =
    StateNotifierProvider<AppLockController, bool>(
      (ref) => AppLockController(AppLockHost.forRef(ref)),
    );
