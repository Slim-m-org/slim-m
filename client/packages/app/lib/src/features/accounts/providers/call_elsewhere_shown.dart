// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the call another account holds is already on screen, so the call
/// pill steps aside. See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A count of the places on screen that show the call elsewhere, taken as they
/// mount (unlike `VisibleHold`), so a pill built after the rail never draws.
class CallElsewhereShown extends ChangeNotifier {
  int _places = 0;
  bool _disposed = false;

  /// True while at least one place shows the call.
  bool get shown => _places > 0;

  void add() => _change(1);

  void remove() => _change(-1);

  void _change(int delta) {
    final before = shown;
    _places += delta;
    if (shown == before) return;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    // Places mount and unmount mid-build, when the pill cannot be marked dirty.
    binding.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final callElsewhereShownProvider = Provider<CallElsewhereShown>((ref) {
  final shown = CallElsewhereShown();
  ref.onDispose(shown.dispose);
  return shown;
});
