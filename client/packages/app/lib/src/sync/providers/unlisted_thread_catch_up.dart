// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Catch-up for threads this device holds no row for.
///
/// A thread is never listed, so the store has no cursor to ask `/sync` from. This keeps one in memory for each thread a live frame named, so a reconnect can fetch what it missed and hand it to alerts, without storing anything.
library;

import 'package:slimm_api/api.dart';

/// Threads tracked at once; the least recently heard from are forgotten first.
const unlistedThreadLimit = 100;

/// Pages asked per thread in one catch-up, so a huge backlog cannot hold a connect.
const _maxPages = 5;

class _Thread {
  _Thread(this.cursor);

  /// Everything at or below this seq is announced or deliberately skipped.
  int cursor;

  /// Ids above [cursor] a live frame already announced.
  final announced = <String>{};
}

class UnlistedThreadCatchUp {
  final _threads = <String, _Thread>{};

  /// Records a live frame for a thread with no row. A first frame starts the cursor at itself, so history before it is never announced.
  void noteLive(Message message) {
    final thread = _threads.remove(message.channelId) ?? _Thread(message.seq);
    _threads[message.channelId] = thread;
    if (message.seq == thread.cursor + 1) {
      thread.cursor = message.seq;
    } else if (message.seq > thread.cursor) {
      thread.announced.add(message.id);
    }
    if (_threads.length > unlistedThreadLimit) {
      _threads.remove(_threads.keys.first);
    }
  }

  /// What the tracked threads received past their cursors that no live frame announced.
  Future<List<Message>> missed(SlimmApi api) async {
    final found = <Message>[];
    var pending = _threads.keys.toSet();
    for (var page = 0; page < _maxPages && pending.isNotEmpty; page++) {
      final deltas = await api.sync([
        for (final id in pending)
          ScopeCursor(channelId: id, afterSeq: _threads[id]!.cursor),
      ]);
      pending = {};
      for (final delta in deltas) {
        final thread = _threads[delta.channelId];
        if (thread == null) continue;
        if (!delta.reset) {
          found.addAll(
            delta.messages.where((m) => !thread.announced.contains(m.id)),
          );
        }
        _advance(thread, delta);
        if (delta.hasMore && !delta.reset) pending.add(delta.channelId);
      }
    }
    return found;
  }

  void _advance(_Thread thread, ScopeDelta delta) {
    final top = delta.messages.fold(
      delta.reset ? (delta.latestSeq ?? thread.cursor) : thread.cursor,
      (seq, m) => m.seq > seq ? m.seq : seq,
    );
    thread.cursor = top;
    thread.announced.removeWhere((id) => delta.messages.any((m) => m.id == id));
  }
}
