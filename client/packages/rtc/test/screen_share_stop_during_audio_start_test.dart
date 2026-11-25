// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stop tapped while the share mix is still starting must win: no share is
/// published afterwards and no false "PipeWire tools not found" note appears.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_share_audio_graph.dart';

class _DesktopBridge implements BroadcastBridge {
  @override
  bool get usesBroadcastExtension => false;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<void> requestStop() async {}
  @override
  set autoPublishEnabled(bool enabled) {}
  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}

void main() {
  test('stopping while the mix starts publishes nothing and leaves no note',
      () async {
    final graph = FakeShareAudioGraph()..holdCreate = Completer<void>();
    final isolation = ShareAudioIsolation(graph: graph);
    final control = ScreenShareControl(_DesktopBridge(), isolation: isolation);
    final published = <bool>[];
    Future<void> publish(
        bool on, lk.ScreenShareCaptureOptions? o, bool a) async {
      published.add(on);
    }

    final start = control.setEnabled(
      true,
      quality: ScreenShareQuality.standard,
      includeAudio: true,
      publish: publish,
      isSharing: () => published.contains(true),
      onSettled: (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    final stop = control.setEnabled(
      false,
      quality: ScreenShareQuality.standard,
      publish: publish,
      isSharing: () => false,
      onSettled: (_) {},
    );
    graph.holdCreate!.complete();

    expect(await start, ScreenShareOutcome.stopped);
    await stop;
    expect(published, [false]);
    expect(shareAudioNote.value, isNull);
    expect(isolation.active, isFalse);
  });
}
