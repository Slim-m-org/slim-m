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
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show TokenPair;
import 'package:slimm_platform/platform.dart';

import 'app_lock_preference.dart';
import 'providers.dart';

/// The seam onto `BiometricAuthChannel`. A provider, like
/// `apnsTokenChannelProvider`, so a test can substitute a fake that needs no
/// real biometric hardware or platform channel behind it.
final biometricAuthChannelProvider = Provider<BiometricAuthChannel>(
  (ref) => BiometricAuthChannel(),
);

class AppLockController extends StateNotifier<bool>
    with WidgetsBindingObserver {
  AppLockController(this._ref) : super(false) {
    WidgetsBinding.instance.addObserver(this);
    _sessionSubscription = _ref.read(sessionProvider).changes.listen((
      TokenPair? tokens,
    ) {
      // A real sign-out already means typing a password again; nothing left to lock.
      if (tokens == null) state = false;
    });
  }

  final Ref _ref;
  late final StreamSubscription<TokenPair?> _sessionSubscription;
  DateTime? _backgroundedAt;

  /// How long slim-m can sit backgrounded before its next resume asks for
  /// Face ID/a fingerprint again.
  static const lockGraceDuration = Duration(seconds: 30);

  bool get _enabled => _ref.read(appLockPreferenceProvider);
  bool get _signedIn => _ref.read(sessionProvider).isSignedIn;

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
    if (!_enabled || !_signedIn) return;
    // Matches PushController's own iOS `inactive` reasoning: a visible-but-unfocused app is not backgrounded.
    final backgrounded =
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive;
    if (backgrounded) {
      _backgroundedAt ??= clock.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since != null && clock.now().difference(since) >= lockGraceDuration) {
      this.state = true;
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
    final channel = _ref.read(biometricAuthChannelProvider);
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
    await _ref.read(appLockPreferenceProvider.notifier).set(false);
    state = false;
  }

  @override
  void dispose() {
    unawaited(_sessionSubscription.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLockControllerProvider =
    StateNotifierProvider<AppLockController, bool>(AppLockController.new);
