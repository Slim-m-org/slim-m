// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The state machine behind a bot button press and a bot menu or call use.
///
/// Each is keyed, marked pending with a fresh id, failed after a timeout or a
/// refusal, and cleared when the bot answers (`interaction.answered`). One
/// copy here, so a fix to the timeout or the stale-id guard lands once.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show protected;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../ids.dart';
import 'live_events.dart';

const _didNotAnswer =
    'The bot did not answer. It may be offline, so try again in a moment.';

abstract class PendingInteractions<V> extends StateNotifier<Map<String, V>> {
  PendingInteractions(Ref ref, this._timeout) : super(const {}) {
    _sub = ref.read(liveEventsProvider).listen((event) {
      if (event case api.InteractionAnswered(:final interactionId)) {
        _answered(interactionId);
      }
    });
  }

  final Duration _timeout;
  late final StreamSubscription<api.ServerEvent> _sub;
  final Map<String, Timer> _timers = {};

  @protected
  String idOf(V value);

  @protected
  bool isPending(V value);

  /// [current] turned into its failed form carrying [failure].
  @protected
  V failed(V current, String failure);

  /// Marks [key] pending and sends; a no-op while [key] is already pending.
  @protected
  Future<void> start(
    String key, {
    required V Function(String id) pending,
    required Future<void> Function(String id) send,
    required String Function(api.ApiException error) describe,
  }) async {
    final existing = state[key];
    if (existing != null && isPending(existing)) return;
    final id = newMessageId();
    state = {...state, key: pending(id)};
    _timers[key]?.cancel();
    _timers[key] = Timer(_timeout, () => _fail(key, id, _didNotAnswer));
    try {
      await send(id);
    } on api.ApiException catch (e) {
      _fail(key, id, describe(e));
    }
  }

  void _answered(String interactionId) {
    for (final entry in state.entries) {
      if (idOf(entry.value) != interactionId) continue;
      _timers.remove(entry.key)?.cancel();
      _remove(entry.key);
      return;
    }
  }

  void _fail(String key, String id, String failure) {
    final current = state[key];
    if (current == null || idOf(current) != id || !isPending(current)) return;
    _timers.remove(key)?.cancel();
    state = {...state, key: failed(current, failure)};
  }

  /// Clears a failure the person has read; a pending or missing key stays.
  @protected
  void dismissKey(String key) {
    final current = state[key];
    if (current == null || isPending(current)) return;
    _remove(key);
  }

  void _remove(String key) {
    state = {
      for (final entry in state.entries)
        if (entry.key != key) entry.key: entry.value,
    };
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
