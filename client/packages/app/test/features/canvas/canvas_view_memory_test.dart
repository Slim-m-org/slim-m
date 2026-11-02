// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Swapping the canvas for the voice lounge and back returns each channel's
/// shared-view pan and zoom; following someone wins over the kept view.
library;

import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/fake_api.dart';
import 'canvas_pane_harness.dart';

const _viewport = Size(1280, 720);

Object _get(String path) {
  if (path.endsWith('/canvas/media-slots')) return {'slots': <Object>[]};
  if (path.endsWith('/canvas/object-locks')) return {'object_ids': <Object>[]};
  if (path.endsWith('/canvas/ops')) {
    return {
      'ops': <Object>[],
      'latest_seq': 0,
      'has_more': false,
      'reset': false,
    };
  }
  if (path.endsWith('/canvas/objects')) {
    return {'objects': <Object>[], 'has_more': false, 'latest_seq': 0};
  }
  return <Object>[];
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CanvasPaneFixture fixture;
  late ProviderContainer container;

  setUp(() {
    fixture = CanvasPaneFixture();
    container = fixture.container(
      extraOverrides: [
        mockApiOverride(
          (request) async => jsonResponse(_get(request.url.path)),
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await fixture.events.close();
    await _settle();
  });

  Future<(CanvasEngine, ProviderSubscription<Object?>)> open(String id) async {
    final sub = container.listen(canvasEngineProvider(id), (_, _) {});
    final engine = container.read(canvasEngineProvider(id).notifier);
    engine.document.setViewport(_viewport);
    await _settle();
    return (engine, sub);
  }

  Camera panned() =>
      Camera(x: 1500, y: 1100, zoom: boardFitZoom(canvasBoard, _viewport) * 3);

  test('the canvas reopens where it was left', () async {
    final (first, sub) = await open('c1');
    first.document.setCamera(panned());
    final left = first.document.camera;
    expect(first.document.isFitted, isFalse);
    sub.close();
    await _settle();

    final (second, _) = await open('c1');
    expect(second.document.camera, left);
  });

  test('another channel is not moved by it', () async {
    final (first, sub) = await open('c1');
    first.document.setCamera(panned());
    sub.close();
    await _settle();

    final (other, _) = await open('c2');
    expect(other.document.isFitted, isTrue);
  });

  test('coming back to the fit forgets the old pan', () async {
    final (first, sub) = await open('c1');
    first.document.setCamera(panned());
    first.document.fitBoard();
    sub.close();
    await _settle();

    final (second, _) = await open('c1');
    expect(second.document.isFitted, isTrue);
  });

  test('following someone is not kept as the viewer\'s own view', () async {
    final (first, sub) = await open('c1');
    first.document.setCamera(panned());
    first.viewRelay.following.value = 'u2';
    sub.close();
    await _settle();

    final (second, _) = await open('c1');
    expect(second.viewRelay.following.value, isNull);
    expect(second.document.camera, isNot(first.document.camera));
  });
}
