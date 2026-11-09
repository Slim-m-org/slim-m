// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One wrapper that stops animated media nobody is looking at.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle.dart';
import '../providers/overlay_cover.dart';
import 'viewport_freeze.dart';

/// Pauses every animated image below it while it is scrolled out of view, the
/// window is unfocused, or another route (a sheet, a dialog) covers it.
///
/// A non-opaque route leaves the page beneath it mounted and ticking, so the
/// route's own `isCurrent` and the root navigator's [overlayCoverProvider] are
/// read. Only an overlay above the gate's own route counts: the images of the
/// sheet that is open play.
class AnimationGate extends ConsumerWidget {
  const AnimationGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused = ref.watch(appFocusedProvider);
    final route = ModalRoute.of(context);
    final covered = ref.watch(
      overlayCoverProvider.select((stack) => stack.covers(route)),
    );
    final uncovered = (route?.isCurrent ?? true) && !covered;
    return ViewportFreeze(
      child: TickerMode(enabled: focused && uncovered, child: child),
    );
  }
}
