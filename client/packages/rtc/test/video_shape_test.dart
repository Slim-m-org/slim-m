// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/src/video_shape.dart';

void main() {
  testWidgets('reports each new frame shape once, and nothing before a frame', (
    tester,
  ) async {
    final shapes = <double>[];
    final renderer = rtc.RTCVideoRenderer();
    await tester.pumpWidget(
      VideoShapeScope(
        onShape: shapes.add,
        child: VideoShapeReporter(
          renderer: renderer,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    expect(shapes, isEmpty);

    renderer.value = const rtc.RTCVideoValue(width: 1920, height: 1080);
    renderer.value = const rtc.RTCVideoValue(
      width: 1920,
      height: 1080,
      renderVideo: true,
    );
    renderer.value = const rtc.RTCVideoValue(width: 1080, height: 1080);

    expect(shapes, [1920 / 1080, 1.0]);
  });

  testWidgets('stays silent with no scope above it', (tester) async {
    final renderer = rtc.RTCVideoRenderer();
    await tester.pumpWidget(
      VideoShapeReporter(renderer: renderer, child: const SizedBox.shrink()),
    );
    renderer.value = const rtc.RTCVideoValue(width: 640, height: 480);
    expect(tester.takeException(), isNull);
  });
}
