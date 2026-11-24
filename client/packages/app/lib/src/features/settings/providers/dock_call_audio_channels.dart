// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice channels an admin lets a module hear (decision 0105): read when
/// the module's page opens, replaced as a whole when a channel is switched.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../api_failure.dart';
import '../../../providers/providers.dart';

class DockCallAudioChannels {
  const DockCallAudioChannels({
    this.ids = const [],
    this.error,
    this.saving = false,
  });

  /// The list the server last confirmed.
  final List<String> ids;

  /// Whether a change is still on its way, so the rows wait for it.
  final bool saving;

  /// Why the last change was refused, until the next one.
  final String? error;
}

class DockCallAudioChannelsController
    extends AutoDisposeFamilyAsyncNotifier<DockCallAudioChannels, String> {
  @override
  Future<DockCallAudioChannels> build(String moduleId) async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final ids = await ref.watch(apiProvider).callAudioChannels(moduleId);
    return DockCallAudioChannels(ids: ids);
  }

  var _tail = Future<void>.value();
  var _pending = 0;
  var _disposed = false;

  /// Arms or disarms [channelId], keeping the rest of the list; changes run one after another, each from the list the last one confirmed.
  Future<void> toggle(String channelId, {required bool armed}) {
    final held = state.valueOrNull;
    if (held != null) state = AsyncData(_with(held, saving: true));
    _pending++;
    final run = _tail.then((_) => _apply(channelId, armed));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  DockCallAudioChannels _with(
    DockCallAudioChannels held, {
    List<String>? ids,
    String? error,
    required bool saving,
  }) =>
      DockCallAudioChannels(ids: ids ?? held.ids, error: error, saving: saving);

  Future<void> _apply(String channelId, bool armed) async {
    final held = state.valueOrNull ?? const DockCallAudioChannels();
    final next = [
      for (final id in held.ids)
        if (id != channelId) id,
      if (armed) channelId,
    ];
    var ids = held.ids;
    String? error;
    try {
      ids = await ref.read(apiProvider).setCallAudioChannels(arg, next);
    } catch (e, stack) {
      error = reportFailureSentence(
        api.LogTag.ui,
        'change the calls it can hear',
        e,
        stack,
      );
    } finally {
      _pending--;
    }
    if (_disposed) return;
    state = AsyncData(
      _with(held, ids: ids, error: error, saving: _pending > 0),
    );
  }
}

final dockCallAudioChannelsProvider = AsyncNotifierProvider.autoDispose
    .family<DockCallAudioChannelsController, DockCallAudioChannels, String>(
      DockCallAudioChannelsController.new,
    );
