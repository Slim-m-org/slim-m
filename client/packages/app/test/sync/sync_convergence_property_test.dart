// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whatever the socket loses, repeats or reorders, and however a catch-up's
/// answer interleaves with it, one quiet catch-up leaves the local store
/// agreeing with the server: no message missing, none stale, none that the
/// server deleted.
///
/// Seeded, so a failure names the seed that reproduces it; each finding is
/// also pinned in `sync_convergence_findings_test.dart`.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;

import '../support/fuzz_budget.dart';
import '../support/sync_model_server.dart';
import '../support/sync_model_world.dart';

/// Limits small enough that paging and both reset branches are reached.
SyncModelServer _smallServer() => SyncModelServer(
  perScopeLimit: 4,
  snapshotGap: 25,
  opsPerScopeLimit: 3,
  opSnapshotGap: 20,
  newestPage: 6,
);

/// One step of a run: the server writes, or one tab's wire or catch-up moves.
Future<void> _step(
  List<SyncModelWorld> tabs,
  Random random,
  List<String> trail,
) async {
  final server = tabs.first.server;
  // Two tabs are held to what one socket can do: frames in order, and a loss is everything in flight.
  final oneSocket = tabs.length > 1;
  final tab = random.nextInt(tabs.length);
  final world = tabs[tab];
  void fanOut(api.ServerEvent frame) {
    for (final each in tabs) {
      each.wire.add(frame);
    }
  }

  final roll = random.nextInt(100);
  final live = server.live.toList();
  if (roll < 22 || live.isEmpty) {
    trail.add('send');
    fanOut(server.send('v${random.nextInt(1 << 20)}'));
  } else if (roll < 42) {
    final target = live[random.nextInt(live.length)];
    trail.add('edit ${target.id}');
    fanOut(server.edit(target, 'e${random.nextInt(1 << 20)}'));
  } else if (roll < 50) {
    final target = live[random.nextInt(live.length)];
    trail.add('delete ${target.id}');
    fanOut(server.delete(target));
  } else if (roll < 78) {
    if (world.wire.isNotEmpty) {
      final early = !oneSocket && world.wire.length > 1;
      final at = early && random.nextInt(8) == 0 ? 1 : 0;
      final repeat = random.nextInt(10) == 0;
      trail.add(
        'tab $tab: deliver ${world.wire[at].runtimeType} at $at, repeat $repeat',
      );
      await world.deliver(at: at, repeat: repeat);
    }
  } else if (roll < 82) {
    if (world.wire.isEmpty) {
      // Nothing in flight to lose.
    } else if (oneSocket) {
      trail.add('tab $tab: the socket is cut, then catch up');
      await world.settle();
    } else {
      trail.add('tab $tab: lose a frame');
      world.wire.removeAt(0);
    }
  } else if (roll < 90) {
    world.holdAnswers = random.nextBool();
    trail.add('tab $tab: catch up, answer held: ${world.holdAnswers}');
    unawaited(world.controller.reconcile());
  } else {
    trail.add('tab $tab: release an answer');
    world.releaseAnswer();
  }
  await pumpEventQueue(times: 5);
}

/// Runs [seed] over [tabCount] tabs sharing one database, and says how the store ends up wrong.
/// Lower [steps] by hand to find the shortest run that still fails.
Future<String?> _run(int seed, {int tabCount = 1, int steps = 70}) async {
  final first = SyncModelWorld(server: _smallServer());
  final tabs = [
    first,
    for (var i = 1; i < tabCount; i++)
      SyncModelWorld(server: first.server, sharing: first),
  ];
  final random = Random(seed);
  final trail = <String>[];
  for (final tab in tabs) {
    await tab.open();
  }
  try {
    for (var i = 0; i < steps; i++) {
      await _step(tabs, random, trail);
    }
    for (final tab in tabs) {
      await tab.settle();
    }
    final wrong = await first.disagreement();
    return wrong == null ? null : '$wrong\n  ${trail.join('\n  ')}';
  } finally {
    for (final tab in tabs.reversed) {
      await tab.close();
    }
  }
}

void main() {
  test('the store agrees with the server after any run of lost, repeated and '
      'reordered frames and delayed catch-ups', () async {
    final seeds = fuzzSeeds(full: 3000, quick: 150);
    for (var seed = 0; seed < seeds; seed++) {
      final wrong = await _run(seed);
      expect(wrong, isNull, reason: 'seed $seed: $wrong');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('two tabs on one database, each behind the other at times, still '
      'agree with the server', () async {
    final seeds = fuzzSeeds(full: 3000, quick: 150);
    for (var seed = 0; seed < seeds; seed++) {
      final wrong = await _run(seed, tabCount: 2);
      expect(wrong, isNull, reason: 'seed $seed: $wrong');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
