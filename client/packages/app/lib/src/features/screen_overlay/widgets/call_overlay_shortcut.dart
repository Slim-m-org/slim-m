// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The key that shows or hides the call overlay while the app has focus.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/call_overlay_toggle.dart';
import '../providers/screen_overlay_controller.dart';

/// Empty where the overlay cannot be hosted, so the browser or the OS keeps the key.
Map<ShortcutActivator, VoidCallback> callOverlayShortcutBindings(
  WidgetRef ref,
) {
  final key = activatorFor(AppAction.toggleCallOverlay);
  if (key == null || !ref.watch(screenOverlaySupportedProvider)) {
    return const {};
  }
  return {key: ref.read(toggleCallOverlayProvider)};
}
