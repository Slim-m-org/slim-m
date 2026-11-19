// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

import 'android_push_messages.dart';

/// Wires Firebase and the FCM background message handler Android needs to
/// ever show a notification while backgrounded or killed - the relay sends
/// data-only messages, so nothing appears unless this app builds it (see
/// `src/push/android_push_messages.dart`). Deliberately does not also listen
/// for foreground messages: see that file's doc for why a foreground push
/// never needs to show anything of its own.
///
/// Must run before [runApp], and the background handler must be registered
/// here specifically rather than from a provider or a widget: FCM invokes it
/// in its own isolate with no widget tree and no [ProviderContainer], so it
/// has to already be a reachable top-level function before that isolate can
/// exist. A no-op on iOS, Linux and the web, and best-effort even on Android:
/// a contributor's build with no `google-services.json` (see
/// `android/app/build.gradle.kts`) throws here, and push, like on iOS, must
/// never be the reason the rest of the app fails to start.
///
/// Swallowing that throw loses nothing, because the same missing credentials or
/// absent Play Services also degrade push registration through
/// `FcmTokenChannel`, and showing notifications cannot work without a token to
/// register in the first place.
Future<void> initAndroidPush() async {
  if (!isAndroidHost) return;
  try {
    await ensureFirebaseInitialized();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'Push notifications are off: no Firebase setup or Play Services on this device',
      error,
      stack,
    );
  }
}
