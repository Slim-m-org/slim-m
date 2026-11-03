// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice channels an admin lets a module hear (decision 0105): read when
/// the module's page opens, replaced as a whole when a channel is switched.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

class DockCallAudioChannels {
  const DockCallAudioChannels({this.ids = const [], this.error});

  final List<String> ids;

  /// Why the last change was refused, until the next one.
  final String? error;
}

class DockCallAudioChannelsController
    extends AutoDisposeFamilyAsyncNotifier<DockCallAudioChannels, String> {
  @override
  Future<DockCallAudioChannels> build(String moduleId) async {
    final ids = await ref.watch(apiProvider).callAudioChannels(moduleId);
    return DockCallAudioChannels(ids: ids);
  }

  /// Arms or disarms [channelId], keeping the rest of the list.
  Future<void> toggle(String channelId, {required bool armed}) async {
    final current = state.valueOrNull?.ids ?? const <String>[];
    final next = [
      for (final id in current)
        if (id != channelId) id,
      if (armed) channelId,
    ];
    try {
      final saved = await ref.read(apiProvider).setCallAudioChannels(arg, next);
      state = AsyncData(DockCallAudioChannels(ids: saved));
    } on api.ApiException catch (error) {
      state = AsyncData(
        DockCallAudioChannels(ids: current, error: error.message),
      );
    }
  }
}

final dockCallAudioChannelsProvider = AsyncNotifierProvider.autoDispose
    .family<DockCallAudioChannelsController, DockCallAudioChannels, String>(
      DockCallAudioChannelsController.new,
    );
