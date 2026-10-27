// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The cache's hot reads must be served by an index, not a scan of `messages`.
/// Each test captures the SQL the store really runs and asks sqlite how it
/// would execute it.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/database.dart'
    show MessagesCompanion, pendingOrFailedIdsSql;

class _Capture extends QueryInterceptor {
  final statements = <({String sql, List<Object?> args})>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor inner,
    String statement,
    List<Object?> args,
  ) {
    statements.add((sql: statement, args: args));
    return inner.runSelect(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor inner,
    String statement,
    List<Object?> args,
  ) {
    statements.add((sql: statement, args: args));
    return inner.runUpdate(statement, args);
  }
}

final _fullScan = matches(RegExp(r'SCAN messages\s*$', multiLine: true));

void main() {
  late _Capture capture;
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() async {
    capture = _Capture();
    db = SlimmDatabase(NativeDatabase.memory().interceptWith(capture));
    store = MessageStore(db);
    await db.customSelect('SELECT 1').get();
    capture.statements.clear();
  });

  tearDown(() => db.close());

  Future<String> plan(String sql, List<Object?> args) async {
    final rows = await db.customSelect(
      'EXPLAIN QUERY PLAN $sql',
      variables: [for (final a in args) Variable<Object>(a)],
    ).get();
    return rows.map((r) => r.read<String>('detail')).join('\n');
  }

  Future<String> planOfLast(String contains) {
    final s = capture.statements.lastWhere((s) => s.sql.contains(contains));
    return plan(s.sql, s.args);
  }

  test('hasMessageFrom is served by the author index', () async {
    await hasMessageFrom(store, 'u1');

    final detail = await planOfLast('author_id');
    expect(detail, contains('messages_author'));
    expect(detail, isNot(_fullScan));
  });

  test('failedMessages uses the partial failed index', () async {
    await store.failedMessages();

    final detail = await planOfLast('"failed"');
    expect(detail, contains('messages_failed'));
    expect(detail, isNot(_fullScan));
  });

  test('the interrupted-send sweep uses the partial pending index', () async {
    await failInterruptedSends(store);

    final detail = await planOfLast('"pending"');
    expect(detail, contains('messages_pending'));
  });

  test('the pending-attachment cleanup subquery avoids a table scan', () async {
    final detail = await plan(
      'SELECT id FROM ($pendingOrFailedIdsSql)',
      const [],
    );
    expect(detail, contains('messages_pending'));
    expect(detail, contains('messages_failed'));
    expect(detail, isNot(_fullScan));
  });

  test('reachableMessageIds reads only the id column', () async {
    await store.addPending(
      id: 'm1',
      channelId: 'c1',
      authorId: 'u1',
      content: 'a long body that must not be loaded',
    );
    capture.statements.clear();

    expect(await store.reachableMessageIds(['c1']), {'m1'});

    final sql = capture.statements.single.sql;
    expect(sql, isNot(contains('content')));
    expect(sql, isNot(contains('*')));
  });

  group('transcript query', () {
    Future<void> seed() async {
      final rows = <MessagesCompanion>[];
      for (var i = 0; i < 40; i++) {
        rows.add(_row('d$i', 'c1', seq: i + 1, createdAt: 1000 - i * 7 % 13));
      }
      for (var i = 0; i < 6; i++) {
        rows.add(_row('p$i', 'c1', seq: 0, createdAt: 2000 + i * 3));
      }
      rows.add(_row('o1', 'c2', seq: 0, createdAt: 1));
      rows.add(_row('o2', 'c2', seq: 9, createdAt: 1));
      await db.batch((b) => b.insertAll(db.messages, rows));
    }

    test('orders rows exactly as the old seq = 0 first query did', () async {
      await seed();
      for (final limit in [3, 8, 46, 200]) {
        final old = await (db.select(db.messages)
              ..where((m) => m.channelId.equals('c1'))
              ..orderBy([
                (m) => OrderingTerm(
                    expression: m.seq.equals(0), mode: OrderingMode.desc),
                (m) => OrderingTerm(expression: m.seq, mode: OrderingMode.desc),
                (m) => OrderingTerm(
                    expression: m.createdAt, mode: OrderingMode.desc),
              ])
              ..limit(limit))
            .get();

        final now = await store.channelSnapshot('c1', limit: limit);

        expect(now.map((m) => m.id).toList(),
            old.reversed.map((r) => r.id).toList(),
            reason: 'limit $limit');
      }
    });

    test('is served by the channel/seq index with no full scan', () async {
      await store.channelSnapshot('c1');

      final detail = await planOfLast('grp');
      expect(detail, contains('messages_channel_seq'));
      expect(detail, isNot(_fullScan));
    });
  });
}

MessagesCompanion _row(
  String id,
  String channelId, {
  required int seq,
  required int createdAt,
}) =>
    MessagesCompanion.insert(
      id: id,
      channelId: channelId,
      content: id,
      createdAt: createdAt,
      seq: Value(seq),
    );
