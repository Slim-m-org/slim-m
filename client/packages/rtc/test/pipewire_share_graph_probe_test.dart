// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starting a share must not wait on a healthy sound server, only learn quickly that there is none.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/share_audio_graph_io.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pw-cli-fake'));
  tearDown(() => dir.deleteSync(recursive: true));

  String fake(String body) {
    final file = File('${dir.path}/pw-cli')
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  test('a daemon that greets is trusted at once, without the full probe',
      () async {
    final graph = PipewireShareGraph(cli: fake('echo Welcome; sleep 30'));
    final clock = Stopwatch()..start();

    final made = await graph.createMix('slimm-test-mix');
    final took = clock.elapsed;
    await graph.destroy();

    expect(made, isTrue);
    expect(took, lessThan(const Duration(milliseconds: 300)));
  });

  test('a missing daemon is reported without waiting for the probe', () async {
    final graph = PipewireShareGraph(
      cli: fake('echo "Error: failed to connect" >&2; exit 1'),
    );

    expect(await graph.createMix('slimm-test-mix'), isFalse);
  });

  test('a quiet daemon is still trusted once the probe passes', () async {
    final graph = PipewireShareGraph(cli: fake('sleep 30'));

    expect(await graph.createMix('slimm-test-mix'), isTrue);
    await graph.destroy();
  });
}
