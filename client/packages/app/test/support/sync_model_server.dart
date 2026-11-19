// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One channel of the server's message and op streams, small enough to drive
/// from a seed: what `POST /sync` and the newest page answer, and the frames
/// a write fans out.
///
/// It mirrors `http/sync.rs` and `http/sync_ops.rs`, with limits a test can
/// shrink so paging and the reset branches are reached in a few dozen writes.
library;

import 'package:slimm_api/api.dart' as api;

class ModelMessage {
  ModelMessage(this.id, this.seq, this.content, this.createdAt);

  final String id;
  final int seq;
  String content;
  final int createdAt;
  int? editedAt;
  bool deleted = false;

  Map<String, dynamic> toJson(String channelId) => {
    'id': id,
    'channel_id': channelId,
    'author_id': 'alice',
    'author_display_name': 'Alice',
    'seq': seq,
    'content': content,
    'created_at': createdAt,
    'edited_at': editedAt,
  };
}

class _ModelOp {
  const _ModelOp(this.seq, this.kind, this.message);

  final int seq;
  final String kind;
  final ModelMessage message;
}

class SyncModelServer {
  SyncModelServer({
    this.channelId = 'c1',
    this.perScopeLimit = 100,
    this.snapshotGap = 1000,
    this.opsPerScopeLimit = 100,
    this.opSnapshotGap = 2000,
    this.newestPage = 50,
    this.reportsHead = true,
  });

  final String channelId;
  final int perScopeLimit;
  final int snapshotGap;
  final int opsPerScopeLimit;
  final int opSnapshotGap;
  final int newestPage;

  /// False for a server that predates `latest_seq`.
  final bool reportsHead;

  final messages = <ModelMessage>[];
  final _ops = <_ModelOp>[];
  int _clock = 1000;

  int get head => messages.length;
  int get opHead => _ops.length;

  Iterable<ModelMessage> get live => messages.where((m) => !m.deleted);

  api.ServerEvent send(String content) {
    final seq = messages.length + 1;
    final message = ModelMessage('m$seq', seq, content, _clock++);
    messages.add(message);
    return api.MessageCreated(_wire(message));
  }

  api.ServerEvent edit(ModelMessage message, String content) {
    message
      ..content = content
      ..editedAt = _clock++;
    _ops.add(_ModelOp(_ops.length + 1, 'edit', message));
    return api.MessageEdited(_wire(message), opSeq: _ops.length);
  }

  api.ServerEvent delete(ModelMessage message) {
    message.deleted = true;
    _ops.add(_ModelOp(_ops.length + 1, 'delete', message));
    return api.MessageDeleted(
      channelId: channelId,
      messageId: message.id,
      opSeq: _ops.length,
    );
  }

  api.Message _wire(ModelMessage message) =>
      api.Message.fromJson(message.toJson(channelId));

  /// The newest page, newest first, as `GET /channels/{id}/messages` answers.
  List<Map<String, dynamic>> newest() => [
    for (final m in live.toList().reversed.take(newestPage))
      m.toJson(channelId),
  ];

  /// One `/sync` body answered against the state as it stands now.
  Map<String, dynamic> sync(Map<String, dynamic> request) => {
    'scopes': [
      for (final scope in request['scopes'] as List<dynamic>)
        if ((scope as Map<String, dynamic>)['channel_id'] == channelId)
          _scope(scope['after_seq'] as int, scope['after_op_seq'] as int?),
    ],
  };

  Map<String, dynamic> _scope(int after, int? afterOp) {
    final ops = _opsHalf(afterOp);
    final newestLive = live.isEmpty ? 0 : live.last.seq;
    final newest = head - after > snapshotGap ? newestLive : head;
    var rows = const <ModelMessage>[];
    var hasMore = false;
    var reset = false;
    if (after > head) {
      reset = true;
    } else if (after >= newest) {
      // Nothing standing past the cursor.
    } else if (newest - after > snapshotGap) {
      hasMore = true;
      reset = true;
    } else {
      final since = live.where((m) => m.seq > after).toList();
      hasMore = since.length > perScopeLimit;
      rows = since.take(perScopeLimit).toList();
    }
    reset = reset || ops.reset;
    return {
      'channel_id': channelId,
      'messages': [for (final m in rows) m.toJson(channelId)],
      'has_more': hasMore,
      'reset': reset,
      'ops': ops.ops,
      'op_latest_seq': opHead,
      'ops_has_more': ops.hasMore,
      'mentioned_seq': ?(reset ? 0 : null),
      'latest_seq': ?(reportsHead ? head : null),
    };
  }

  ({List<Map<String, dynamic>> ops, bool hasMore, bool reset}) _opsHalf(
    int? after,
  ) {
    if (after == null) return (ops: const [], hasMore: false, reset: false);
    final reset = after > opHead || opHead - after > opSnapshotGap;
    if (reset || after == opHead) {
      return (ops: const [], hasMore: false, reset: reset);
    }
    final since = _ops.where((op) => op.seq > after).toList();
    final page = since.take(opsPerScopeLimit).toList();
    final lastEdit = <String, int>{
      for (final op in page)
        if (op.kind == 'edit') op.message.id: op.seq,
    };
    return (
      ops: [
        for (final op in page)
          {
            'seq': op.seq,
            'kind': op.kind,
            'message_id': op.message.id,
            'created_at': 0,
            if (_carriesContent(op, lastEdit)) ...{
              'content': op.message.content,
              'edited_at': op.message.editedAt,
            },
          },
      ],
      hasMore: since.length > opsPerScopeLimit,
      reset: false,
    );
  }

  /// Content is the message's current text, on the last edit naming it in the page only.
  bool _carriesContent(_ModelOp op, Map<String, int> lastEdit) =>
      op.kind == 'edit' &&
      !op.message.deleted &&
      lastEdit[op.message.id] == op.seq;
}
