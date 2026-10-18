// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one place a tap turns into a physical tick.
///
/// A finger gets no cursor and no hover, so on a phone the only pre-action
/// confirmation that a control was actually hit is the haptic. Every tappable
/// component in this system routes through here rather than calling
/// [HapticFeedback] directly, so the "only on a device that has a haptic
/// engine" guard lives in one place instead of at every call site.
///
/// Guarded to iOS and Android on purpose: [HapticFeedback] is a no-op on
/// desktop and web at the engine, but the guard also skips the platform
/// channel round trip those calls would otherwise make on every tap.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Physical feedback for a tap, guarded to the platforms that can produce it.
abstract final class AppHaptics {
  /// The person's own haptics preference; the app sets it, nothing else does.
  static bool enabled = true;

  static bool get _hasEngine =>
      enabled &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// The lightest tick, for selecting a row, a tab, or a menu item: the
  /// common case, and the one every [AppListRow]/[AppButton] tap fires.
  static void selection() {
    if (_hasEngine) HapticFeedback.selectionClick();
  }

  /// A slightly firmer tap, for confirming an action with weight (sending,
  /// toggling a call control): distinct enough from [selection] to feel
  /// deliberate without being a buzz.
  static void impact() {
    if (_hasEngine) HapticFeedback.lightImpact();
  }

  /// A firm tap for an action that completed (a swipe-to-reply committing).
  static void success() {
    if (_hasEngine) HapticFeedback.mediumImpact();
  }

  /// The heaviest tap, for a mention or something that needs attention.
  static void warning() {
    if (_hasEngine) HapticFeedback.heavyImpact();
  }
}
