// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One wrapper that stops animated media nobody is looking at.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle.dart';
import '../providers/overlay_cover.dart';
import 'viewport_freeze.dart';

/// Pauses every animated image below it while it is scrolled out of view, the
/// window is unfocused, or another route (a sheet, a dialog) covers the page.
///
/// A non-opaque route leaves the page beneath it mounted and ticking, so the
/// route's own `isCurrent` and the root navigator's [overlayCoverProvider] are read.
class AnimationGate extends ConsumerWidget {
  const AnimationGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused = ref.watch(appFocusedProvider);
    final uncovered =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        ref.watch(overlayCoverProvider) == 0;
    return ViewportFreeze(
      child: TickerMode(enabled: focused && uncovered, child: child),
    );
  }
}
