// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's private answers, held in memory until dismissed. The transcript draws them.
///
/// Nothing here is stored or fetched: the server never keeps one and offers no
/// way to read it back, so a reload loses them by design. See
/// docs/decisions/0037-ephemeral-bot-messages.md.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';

class EphemeralMessagesController
    extends StateNotifier<Map<String, List<api.EphemeralMessage>>> {
  EphemeralMessagesController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event case api.MessageEphemeral(:final message)) add(message);
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// A redelivered id replaces itself rather than showing twice.
  void add(api.EphemeralMessage message) {
    final current = state[message.channelId] ?? const [];
    final kept = [
      for (final m in current)
        if (m.id != message.id) m,
      message,
    ];
    state = {...state, message.channelId: kept};
  }

  void dismiss(String channelId, String id) {
    final current = state[channelId];
    if (current == null) return;
    final kept = [
      for (final m in current)
        if (m.id != id) m,
    ];
    state = {...state, channelId: kept};
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Not `autoDispose`: a private answer must survive leaving the channel and
/// coming back. Reset when the session ends.
final ephemeralMessagesProvider =
    StateNotifierProvider<
      EphemeralMessagesController,
      Map<String, List<api.EphemeralMessage>>
    >((ref) => EphemeralMessagesController(ref));

/// One channel's private answers, oldest first.
final channelEphemeralMessagesProvider =
    Provider.family<List<api.EphemeralMessage>, String>(
      (ref, channelId) => ref.watch(
        ephemeralMessagesProvider.select(
          (all) => all[channelId] ?? const <api.EphemeralMessage>[],
        ),
      ),
    );
