// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The optimistic-value pattern of a settings control, in one place: show the
/// tapped value at once, revert it if the save fails, and let the provider's
/// own fresh answer take over once it arrives.
///
/// A refetch that errored still holds the old value, so only an answer that
/// is loaded, not loading and not an error retires the optimistic one:
/// otherwise the control snaps back to what was just replaced.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'run_guarded.dart';

mixin OptimisticSettingState<T extends ConsumerStatefulWidget, V>
    on ConsumerState<T>, GuardedActionState<T> {
  bool _saving = false;
  V? _optimistic;

  /// Whether a save is in flight, to disable the control meanwhile.
  bool get saving => _saving;

  /// What the control shows: the tapped value, else the served one.
  V shown(V? served, V fallback) => _optimistic ?? served ?? fallback;

  /// Shows [next] now and saves it; on success [refresh] is invalidated so
  /// the served value catches up, on failure the tapped value is dropped.
  Future<void> saveOptimistic(
    V next, {
    required String whatFailed,
    required Future<void> Function() action,
    required ProviderOrFamily refresh,
  }) async {
    setState(() {
      _saving = true;
      _optimistic = next;
    });
    final ok = await guard(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _optimistic = null;
    });
    if (ok) ref.invalidate(refresh);
  }

  /// Call from a `ref.listen` on the provider [saveOptimistic] refreshes.
  void retireOptimistic(AsyncValue<Object?> fresh) {
    if (_optimistic == null) return;
    if (!fresh.hasValue || fresh.hasError || fresh.isLoading) return;
    setState(() => _optimistic = null);
  }
}
