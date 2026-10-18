// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bridges this device's FCM registration token from the firebase_messaging
/// plugin.
///
/// Android's push channel needs no bespoke native bridge the way iOS's does
/// (see `ApnsTokenChannel`): Google already ships a plugin that does the
/// async token dance, including rotation. What it does not ship is a seam a
/// test can substitute without a real Android device behind it, which is
/// exactly what [FcmTokenSource] is for - the same interface-behind-a-seam
/// shape [KeyStore] already uses in this package.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

bool _firebaseReady = false;

/// Initializes the default Firebase app exactly once - the single call site for
/// `Firebase.initializeApp()` in the whole client, so the background handler
/// wiring in `main.dart` and this file's token source cannot drift into two
/// separate initialisations of the same app. Idempotent: later calls return at
/// once. Throws on a build with no `google-services.json`, which every caller
/// already treats as an ordinary "push unavailable" outcome, never a crash.
Future<void> ensureFirebaseInitialized() async {
  if (_firebaseReady) return;
  await Firebase.initializeApp();
  _firebaseReady = true;
}

/// The minimal FCM surface [FcmTokenChannel] needs, factored out so a test
/// can supply one that never touches Firebase or a real Android device.
abstract interface class FcmTokenSource {
  /// The current registration token, or null if FCM could not produce one.
  Future<String?> getToken();

  /// Fires every time FCM rotates this device's registration token. A device
  /// that never hears about a rotation, and so never re-registers, silently
  /// stops receiving push - the whole reason this stream exists to be
  /// listened to.
  Stream<String> get onTokenRefresh;
}

/// The real seam, backed by the firebase_messaging plugin.
///
/// Initializes the default Firebase app on first use rather than requiring a
/// separate startup step, so a caller cannot forget it. On a build with no
/// `google-services.json` (see `android/app/build.gradle.kts`, which skips
/// the Gradle plugin that would otherwise fail configuration outright when
/// the file is absent) that init throws, which [FcmTokenChannel.fetch]
/// catches and reports as an ordinary registration failure rather than a
/// crash.
class FirebaseFcmTokenSource implements FcmTokenSource {
  @override
  Future<String?> getToken() async {
    await ensureFirebaseInitialized();
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Stream<String> get onTokenRefresh =>
      FirebaseMessaging.instance.onTokenRefresh;
}

/// What asking FCM for a registration token came back with.
///
/// Mirrors [ApnsTokenResult]'s shape on purpose: a caller reporting push
/// status honestly needs the same three stories on Android as on iOS ("this
/// device cannot", "it tried and failed", "here it is"), even though the
/// underlying plugin resolves a promise rather than the native callback dance
/// iOS's hand-rolled channel needs. There is no `Pending` variant here: FCM's
/// token call either resolves or throws, with nothing to wait out.
sealed class FcmTokenResult {
  const FcmTokenResult();
}

/// This platform has no FCM channel: not Android.
class FcmUnsupported extends FcmTokenResult {
  const FcmUnsupported();
}

/// A usable registration token.
class FcmTokenReady extends FcmTokenResult {
  const FcmTokenReady(this.token);
  final String token;
}

/// FCM could not produce a token, or the attempt to ask it threw. [reason] is
/// whatever the underlying failure says, worth showing verbatim since it is
/// the only diagnosis that reaches Dart at all - a missing
/// `google-services.json`, no Play Services on the device, or a genuine FCM
/// outage all land here rather than three different silent nothings.
class FcmRegistrationFailed extends FcmTokenResult {
  const FcmRegistrationFailed(this.reason);
  final String reason;
}

/// Fetches this device's FCM registration token, and re-announces it
/// whenever FCM rotates it.
///
/// A clean no-op on every platform but Android: nothing on iOS should ever
/// touch Firebase (the relay talks to APNs directly with a device's raw APNs
/// token, and an FCM token would be meaningless there), and Linux desktop has
/// no push channel at all. The web build is excluded for a different reason
/// than desktop: FCM does have a browser transport, but it is Web Push, which
/// needs a VAPID key pair and a service worker this app does not ship, so a
/// browser is honestly unsupported rather than merely unimplemented natively.
/// Deliberately a separate class from
/// [ApnsTokenChannel] rather than one shared abstraction over both: the two
/// platforms' push transports are genuinely different things, and collapsing
/// them behind one interface would make it easy for an iOS call site to
/// silently start depending on Firebase.
class FcmTokenChannel {
  FcmTokenChannel({FcmTokenSource? source, bool? isAndroid})
      : _source = source ?? FirebaseFcmTokenSource(),
        _isAndroid = isAndroid ?? isAndroidHost;

  final FcmTokenSource _source;
  final bool _isAndroid;

  /// The device's current registration token, distinguishing every way one
  /// can be missing so a caller can report push status honestly instead of a
  /// flat null.
  Future<FcmTokenResult> fetch() async {
    if (!_isAndroid) return const FcmUnsupported();
    try {
      final token = await _source.getToken();
      return token == null
          ? const FcmRegistrationFailed('no FCM token was returned')
          : FcmTokenReady(token);
    } catch (e, stack) {
      AppLog.swallowed(
          LogTag.push, 'Could not get a push token from Firebase', e, stack);
      return FcmRegistrationFailed(e.toString());
    }
  }

  /// Fires with each new token FCM rotates in. Permanently empty on every
  /// platform but Android, so a caller can subscribe unconditionally without
  /// its own platform check.
  Stream<String> get onTokenRefresh =>
      _isAndroid ? _source.onTokenRefresh : const Stream.empty();
}
