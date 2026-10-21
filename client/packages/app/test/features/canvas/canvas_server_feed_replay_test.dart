// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Replays op feeds the real Rust server produced (`crates/slimm-server/tests/canvas_ops/export_feed.rs`) through `CanvasSync` the way a reconnect does; the client must end on exactly the server's live set, boxes, paint order and note text.
/// Regenerate with `CANVAS_FEED_EXPORT_DIR=client/packages/app/test/fixtures/canvas_server_feeds cargo nextest run -p slimm-server --test canvas_ops export_feed`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

final Directory _fixtures = Directory('test/fixtures/canvas_server_feeds');

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Replay {
  _Replay(this.session)
    : ops = (session['ops'] as List).cast<Map<String, dynamic>>(),
      objects = (session['objects'] as List).cast<Map<String, dynamic>>() {
    document = CanvasDocument()
      ..setViewport(const Size(2000, 1200))
      ..setCamera(const Camera());
    client = testApi((request) async {
      final after = int.parse(request.url.queryParameters['after_seq']!);
      final rest = ops.where((o) => (o['seq'] as int) > after).toList();
      final page = rest.take(100).toList();
      return jsonHttpResponse({
        'ops': page,
        'latest_seq': session['latest_seq'],
        'has_more': rest.length > page.length,
        'reset': false,
      });
    });
    sync = CanvasSync(
      channelId: 'c1',
      client: client,
      document: document,
      coldFetch: _cold,
      forgetFetchedRegion: () {},
    );
  }

  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> ops;
  final List<Map<String, dynamic>> objects;
  late final CanvasDocument document;
  late final api.SlimmApi client;
  late final CanvasSync sync;

  Future<void> _cold() async {
    for (final json in objects) {
      final input = canvasStrokeInputFrom(api.CanvasObject.fromJson(json));
      if (input != null) document.applyPlaced(input, overwrite: true);
    }
    document.refresh();
  }

  Future<void> run() async {
    sync.seedFromViewport(0);
    await sync.catchUp();
    await _settle();
  }

  void dispose() {
    sync.dispose();
    document.dispose();
    client.close();
  }
}

List<String> _paintedIds(CanvasDocument document) => [
  for (final slot in document.paintOrder) document.strokeAt(slot).id,
];

void _expectSameAsServer(_Replay replay, String label) {
  final document = replay.document..refresh();
  final want = {for (final o in replay.objects) o['id'] as String: o};
  final have = <String>[];
  final out = CullResult();
  document.scene.queryRect(-1e9, -1e9, 1e9, 1e9, out);
  for (final slot in out.slots) {
    if (document.strokeIfAlive(slot) case final stroke?) have.add(stroke.id);
  }
  expect(have.toSet(), want.keys.toSet(), reason: '$label: the live set');
  expect(have.length, have.toSet().length, reason: '$label: no id twice');
  for (final entry in want.entries) {
    final id = entry.key;
    final json = entry.value;
    final box = document.objectBounds(id)!;
    expect(
      [box.x, box.y, box.w, box.h],
      [
        json['x'],
        json['y'],
        json['w'],
        json['h'],
      ].map((v) => (v as num).toDouble()).toList(),
      reason: '$label: box of $id',
    );
    expect(document.zIndexOf(id), json['z_index'], reason: '$label: z of $id');
    if (json['kind'] == 'note') {
      expect(
        document.noteTextOf(id),
        (json['props'] as Map)['text'],
        reason: '$label: text of $id',
      );
    }
  }
  expect(_paintedIds(document), [
    for (final o in replay.objects) o['id'] as String,
  ], reason: '$label: paint order, bottom first');
  expect(
    document.objectCount.value,
    want.length,
    reason: '$label: objectCount',
  );
}

void main() {
  final files = _fixtures.existsSync()
      ? (_fixtures
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  test('the server fixtures are present', () {
    expect(
      files,
      isNotEmpty,
      reason: 'regenerate them; see this file\'s header',
    );
  });

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final session = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    test(
      '$name: a fresh client replaying the whole feed ends on the server state',
      () async {
        final replay = _Replay(session);
        addTearDown(replay.dispose);
        await replay.run();
        expect(replay.sync.asOfSeq, session['latest_seq']);
        _expectSameAsServer(replay, name);
      },
    );

    test('$name: reading the same feed twice changes nothing', () async {
      final replay = _Replay(session);
      addTearDown(replay.dispose);
      await replay.run();
      final again = CanvasSync(
        channelId: 'c1',
        client: replay.client,
        document: replay.document,
        coldFetch: replay._cold,
        forgetFetchedRegion: () {},
      )..seedFromViewport(0);
      addTearDown(again.dispose);
      await again.catchUp();
      await _settle();
      _expectSameAsServer(replay, '$name (second read)');
    });
  }
}
