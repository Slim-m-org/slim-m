// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the level polling that a meter is on screen.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/visible_hold.dart';
import '../providers/level_display.dart';

/// Counts as a displayed meter while it is mounted and its route is shown.
class LevelDisplayHold extends ConsumerWidget {
  const LevelDisplayHold({super.key, required this.child, this.active = true});

  /// False while the meter is not drawn, as when the mic is muted.
  final bool active;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holds = ref.read(levelDisplayHoldsProvider);
    return VisibleHold(
      active: active,
      acquire: () {
        holds.acquire();
      },
      release: () {
        holds.release();
      },
      child: child,
    );
  }
}
