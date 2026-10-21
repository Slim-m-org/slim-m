// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Seeded random sessions against real `CanvasEngine`s on a virtual network.
///
/// Two engines (one a moderator) share a modelled server with three more
/// people acting on it directly. Everything the client does goes through the
/// real engine API: strokes through the commit queue, erase drags, select
/// drags and resizes, delete, reorder, note edits, undo and redo, scoped
/// clears, note and shape placement, locks and camera moves. The network
/// delays, reorders and repeats frames, loses requests before and after the
/// server acts, rate limits, and drops sockets, so local optimistic changes
/// meet late, rejected and missing echoes.
///
/// Each seed ends by settling the network and comparing every client with the
/// server, then replaying the server's whole feed into a fresh document. Every
/// violation is collected by category with the first seed that hit it and how
/// many seeds did; set `CANVAS_FUZZ_TRACE_DIR` to keep the full event trace of
/// each failing seed, `CANVAS_FUZZ_SEEDS` and `CANVAS_FUZZ_FIRST` to rerun a
/// range, `CANVAS_FUZZ_TICKS` to change the length.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_fuzz_actions.dart';
import '../../support/canvas_fuzz_checks.dart';
import '../../support/canvas_fuzz_world.dart';

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

final int _seeds = _env('CANVAS_FUZZ_SEEDS', 200);
final int _first = _env('CANVAS_FUZZ_FIRST', 0);
final int _ticks = _env('CANVAS_FUZZ_TICKS', 520);

/// Re-checks after another catch-up and another cold read, so a mismatch says
/// what it takes to heal it.
void _classify(
  FuzzWorld world,
  FuzzClient client,
  FuzzReport report,
  Set<String> found,
) {
  if (found.isEmpty) return;
  unawaited(client.engine.sync.catchUp());
  world.settle();
  final afterCatchUp = checkAgainstServer(
    world,
    client,
    FuzzReport(),
    prefix: '',
  );
  if (afterCatchUp.isEmpty) {
    report.add(
      world,
      'heal: one more catch-up fixes the mismatch',
      '${client.userId} ${found.length} kinds of mismatch',
    );
    return;
  }
  unawaited(client.engine.fetch());
  world.settle();
  final afterFetch = checkAgainstServer(
    world,
    client,
    FuzzReport(),
    prefix: '',
  );
  report.add(
    world,
    afterFetch.isEmpty
        ? 'heal: only a cold re-read fixes the mismatch'
        : 'heal: nothing short of a pane reopen fixes the mismatch',
    '${client.userId} still wrong after catch-up: $afterCatchUp',
  );
}

/// A fresh document fed the whole feed in seq order, the way a late joiner
/// that opened before anything was drawn would be.
void _replayFresh(FuzzWorld world, FuzzReport report) {
  final server = world.server;
  final document = CanvasDocument()
    ..setViewport(const Size(960, 540))
    ..setBoard(canvasBoard);
  late final CanvasSync sync;
  final client = testApi((request) async {
    if (request.url.path.endsWith('/canvas/ops')) {
      final after = int.parse(request.url.queryParameters['after_seq']!);
      return jsonHttpResponse(server.feed(after, 100));
    }
    return jsonHttpResponse(<Object>[]);
  });
  Future<void> cold() async {
    final page = api.CanvasViewport.fromJson(
      server.viewport({
        'min_x': '-5000',
        'min_y': '-5000',
        'max_x': '5000',
        'max_y': '5000',
        'limit': '2000',
      }),
    );
    for (final object in page.objects) {
      final input = canvasStrokeInputFrom(object);
      if (input != null) document.applyPlaced(input, overwrite: true);
    }
    document.refresh();
  }

  sync = CanvasSync(
    channelId: fuzzChannel,
    client: client,
    document: document,
    coldFetch: cold,
    forgetFetchedRegion: () {},
  );
  sync.seedFromViewport(0);
  unawaited(sync.catchUp());
  world.flush();
  world.elapse(1000);
  checkDocumentAgainstServer(
    world,
    document,
    'fresh replay',
    report,
    prefix: 'replay: ',
  );
  sync.dispose();
  document.dispose();
  client.close();
}

void _runSeed(int seed, FuzzConfig config, FuzzReport report) {
  fakeAsync((async) {
    final world = FuzzWorld(seed, async, config);
    try {
      for (var t = 0; t < _ticks; t++) {
        world.tick();
        if (t % 4 == 0) {
          for (final client in world.clients) {
            checkInternal(world, client, report);
          }
        }
      }
      world.settle();
      if (config.camera) {
        // Back to the whole board, so the comparison is against everything.
        for (final client in world.clients) {
          client.engine.document.fitBoard();
          unawaited(client.engine.fetch());
        }
        world.settle();
      }
      for (final client in world.clients) {
        checkInternal(world, client, report);
        final found = checkAgainstServer(
          world,
          client,
          report,
          prefix: 'settled: ',
        );
        _classify(world, client, report, found);
      }
      _replayFresh(world, report);
    } finally {
      world.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void fuzz(String name, FuzzConfig config) {
    test(name, timeout: const Timeout(Duration(minutes: 20)), () {
      final report = FuzzReport(
        name.split(':').first.replaceAll(RegExp(r'[^a-z]+'), '-'),
      );
      for (var seed = _first; seed < _first + _seeds; seed++) {
        _runSeed(seed, config, report);
      }
      if (report.byCategory.isNotEmpty) fail(report.render());
    });
  }

  final avoid = {
    for (final name in (Platform.environment['CANVAS_FUZZ_AVOID'] ?? '').split(
      ',',
    ))
      if (name.isNotEmpty) name,
  };
  fuzz(
    'a hostile network: every client converges on the server ($_seeds seeds)',
    const FuzzConfig().avoiding(avoid),
  );
  fuzz(
    'a calm network: every client converges on the server ($_seeds seeds)',
    FuzzConfig.calm.avoiding(avoid),
  );
  fuzz(
    'a server that makes slow clients start over: every client converges ($_seeds seeds)',
    const FuzzConfig(resetGap: 12).avoiding(avoid),
  );
  fuzz(
    'people panning and zooming: every client converges once it views the whole board ($_seeds seeds)',
    const FuzzConfig(camera: true).avoiding(avoid),
  );
}
