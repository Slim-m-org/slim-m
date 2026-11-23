// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser capture chain's LiveKit lifecycle with the worklet faked: a mic
/// that cannot be processed goes out raw, a processed one is released and
/// stopped when LiveKit lets it go, and a restart attaches again.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/src/web_capture_chain_processor.dart';

class _Track implements rtc.MediaStreamTrack {
  _Track(this.id);

  @override
  final String id;
  bool stopped = false;

  @override
  Future<void> stop() async => stopped = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Chain {
  final attached = <_Track>[];
  final detached = <rtc.MediaStreamTrack>[];

  /// Set to make the chain unavailable, as a failed worklet load does.
  bool unavailable = false;
  var _outputs = 0;

  Future<rtc.MediaStreamTrack> attach(rtc.MediaStreamTrack track) async {
    attached.add(track as _Track);
    return unavailable ? track : _Track('processed-${++_outputs}');
  }

  Future<void> detach(rtc.MediaStreamTrack processed) async =>
      detached.add(processed);
}

WebCaptureProcessor _processor(_Chain chain) => WebCaptureProcessor(
      name: 'slimm-capture-chain',
      attach: chain.attach,
      detach: chain.detach,
    );

lk.AudioProcessorOptions _options(_Track track) =>
    lk.AudioProcessorOptions(track: track);

void main() {
  test('init publishes what the chain made of the microphone', () async {
    final chain = _Chain();
    final processor = _processor(chain);
    final mic = _Track('mic');

    await processor.init(_options(mic));

    expect(chain.attached, [mic]);
    expect(processor.processedTrack?.id, 'processed-1');
  });

  test('a chain that is unavailable leaves the raw microphone alone', () async {
    final chain = _Chain()..unavailable = true;
    final processor = _processor(chain);
    final mic = _Track('mic');

    await processor.init(_options(mic));
    await processor.destroy();

    expect(processor.processedTrack, isNull);
    expect(chain.detached, isEmpty);
    expect(mic.stopped, isFalse, reason: 'LiveKit owns the raw capture');
  });

  test('destroy releases the chain and stops only the processed track',
      () async {
    final chain = _Chain();
    final processor = _processor(chain);
    final mic = _Track('mic');
    await processor.init(_options(mic));
    final processed = processor.processedTrack! as _Track;

    await processor.destroy();
    await processor.destroy();

    expect(chain.detached, [processed]);
    expect(processed.stopped, isTrue);
    expect(mic.stopped, isFalse);
    expect(processor.processedTrack, isNull);
  });

  test('a restart attaches the new capture again', () async {
    final chain = _Chain();
    final processor = _processor(chain);
    final first = _Track('mic-1');
    final second = _Track('mic-2');
    await processor.init(_options(first));

    await processor.restart(_options(second));

    expect(chain.attached, [first, second]);
    expect(processor.processedTrack?.id, 'processed-2');
  });
}
