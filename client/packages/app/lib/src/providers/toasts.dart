// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transient-confirmation queue behind [AppToast].
///
/// Anything in the app can fire a confirmation with
/// `ref.read(toastsProvider.notifier).show(...)`; [ToastOverlay] renders the
/// live list. Mostly for events that are fine to miss (a copy, a save); a
/// failure is a persistent state, and only one from a closed surface comes here,
/// through `widgets/menu_outcome.dart`. See `design_system/.../surfaces/toast.dart`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

/// One queued confirmation. [id] is monotonic so two identical messages are
/// still distinct entries a reader can dismiss independently.
class ToastMessage {
  const ToastMessage({
    required this.id,
    required this.message,
    required this.severity,
    required this.duration,
  });

  final int id;
  final String message;
  final AppToastSeverity severity;
  final Duration duration;
}

class ToastsController extends StateNotifier<List<ToastMessage>> {
  ToastsController() : super(const []);

  /// At most this many stack at once; an older one is dropped rather than
  /// letting a burst bury the screen. The newest is always kept.
  static const int maxVisible = 4;

  static const Duration defaultDuration = Duration(seconds: 4);

  int _nextId = 0;
  final Map<int, Timer> _timers = {};

  /// Queues a confirmation and returns its id. Auto-dismisses after [duration];
  /// a `Duration.zero` stays until dismissed by hand, for the rare caller that
  /// wants to time it itself.
  int show(
    String message, {
    AppToastSeverity severity = AppToastSeverity.info,
    Duration duration = defaultDuration,
  }) {
    final id = _nextId++;
    var next = [
      ...state,
      ToastMessage(
        id: id,
        message: message,
        severity: severity,
        duration: duration,
      ),
    ];
    if (next.length > maxVisible) {
      for (final dropped in next.take(next.length - maxVisible)) {
        _timers.remove(dropped.id)?.cancel();
      }
      next = next.sublist(next.length - maxVisible);
    }
    state = next;
    if (duration > Duration.zero) {
      _timers[id] = Timer(duration, () => dismiss(id));
    }
    return id;
  }

  void dismiss(int id) {
    _timers.remove(id)?.cancel();
    if (state.any((t) => t.id == id)) {
      state = state.where((t) => t.id != id).toList();
    }
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}

final toastsProvider =
    StateNotifierProvider<ToastsController, List<ToastMessage>>(
      (ref) => ToastsController(),
    );
