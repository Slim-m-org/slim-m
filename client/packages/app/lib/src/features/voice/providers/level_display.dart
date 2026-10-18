// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether any microphone level is on screen, so level polling can drop to
/// the dead-mic watchdog's rate when nothing shows it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_lifecycle.dart';

/// How many mounted, visible meters want a live level. A plain notifier, not
/// provider state: a release while the tree unmounts must not schedule a
/// provider refresh.
class LevelDisplayHolds extends ValueNotifier<int> {
  LevelDisplayHolds() : super(0);

  bool _disposed = false;

  void acquire() {
    if (!_disposed) value++;
  }

  void release() {
    if (!_disposed && value > 0) value--;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final levelDisplayHoldsProvider = Provider<LevelDisplayHolds>((ref) {
  final holds = LevelDisplayHolds();
  ref.onDispose(holds.dispose);
  return holds;
});

/// Calls [onChange] with whether a meter is mounted and visible while the
/// app is resumed, now and on every change.
///
/// Listens to the two state notifiers themselves: a derived [Provider] only
/// refreshes on a frame, and frames stop while the window is hidden, which
/// is exactly when this must turn the polling down.
void listenLevelDisplayed(Ref ref, void Function(bool displayed) onChange) {
  final holds = ref.read(levelDisplayHoldsProvider);
  bool displayed() =>
      holds.value > 0 &&
      ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
  var last = displayed();
  void check(Object? _, Object? next) {
    final now = displayed();
    if (now == last) return;
    last = now;
    onChange(now);
  }

  void onHolds() => check(null, null);
  holds.addListener(onHolds);
  ref.onDispose(() => holds.removeListener(onHolds));
  ref.listen<AppLifecycleState>(appLifecycleProvider, check);
  onChange(last);
}
