// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The path a client takes for a kind it does not know, with a kind that is made up so the test proves the old arm and not this client's own edge arm (decision 0137).
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_edge_inputs.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_object_inputs.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.CanvasObject _object(String kind, Map<String, dynamic> props) =>
    api.CanvasObject(
      id: 'x',
      kind: kind,
      zIndex: 1,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      props: props,
      authorId: 'u',
      seq: 1,
      createdAt: 0,
    );

void main() {
  test(
    'a kind nobody has heard of is skipped by the object converter and by the edge path',
    () {
      final future = _object('hologram', const {'a': 1});
      expect(canvasStrokeInputFrom(future), isNull);
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      expect(applyWireEdge(document, future), isFalse);
      expect(document.objectCount.value, 0);
      expect(document.edges.liveCount, 0);
    },
  );

  test(
    'the object converter does not draw an edge, which only the edge path holds',
    () {
      final edge = _object('edge', {
        'from': {'object_id': 'a'},
        'to': {'x': 1.0, 'y': 2.0},
      });
      expect(canvasStrokeInputFrom(edge), isNull);
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      expect(applyWireEdge(document, edge), isTrue);
      expect(document.edges.liveCount, 1);
    },
  );

  test('a malformed edge is consumed and held by nobody', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    final broken = _object('edge', {'from': 7});
    expect(applyWireEdge(document, broken), isTrue);
    expect(document.edges.liveCount, 0);
  });

  test('a remove naming ids this document never held changes nothing', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.removeObject('never-held', seq: 5);
    document.refresh();
    expect(document.objectCount.value, 0);
    expect(document.edges.liveCount, 0);
  });
}
