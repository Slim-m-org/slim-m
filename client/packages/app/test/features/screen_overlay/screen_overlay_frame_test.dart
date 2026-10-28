// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the overlay is told to paint, and which relayed frames the sharer's client lets through.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_frame.dart';
import 'package:slimm_platform/platform.dart';

final _t0 = DateTime(2026, 10, 28, 12);

api.CanvasScreenAnnotation _frame({
  String kind = 'stroke',
  String target = 'me',
  String channel = 'call',
  List<double> points = const [0.1, 0.2, 0.3, 0.4],
  String? text,
  bool ended = true,
}) => api.CanvasScreenAnnotation(
  channelId: channel,
  userId: 'viewer',
  targetUserId: target,
  kind: kind,
  annotationId: 'a',
  points: points,
  color: 'blue',
  text: text,
  ended: ended,
  allowed: false,
);

void main() {
  group('overlayShapesFor', () {
    List<OverlayShape> shapesOf(api.CanvasScreenAnnotation f, DateTime at) {
      final board = ScreenAnnotationBoard()..apply(f, _t0);
      return overlayShapesFor(board.liveAt(at), at);
    }

    test('a stroke paints as ink in its pen colour at full strength', () {
      final shape = shapesOf(_frame(), _t0).single as OverlayStroke;
      expect(shape.points, [0.1, 0.2, 0.3, 0.4]);
      expect(shape.alpha, 1);
      expect(shape.toJson()['t'], 'stroke');
    });

    test('a lone point is too little to draw', () {
      expect(shapesOf(_frame(points: [0.5, 0.5]), _t0), isEmpty);
    });

    test('a circle paints as an ellipse over its two corners', () {
      final shape =
          shapesOf(_frame(kind: 'shape'), _t0).single as OverlayEllipse;
      expect((shape.x0, shape.y0, shape.x1, shape.y1), (0.1, 0.2, 0.3, 0.4));
    });

    test('a note carries its text and corner', () {
      final shape =
          shapesOf(
                _frame(kind: 'note', points: [0.4, 0.5], text: 'hi'),
                _t0,
              ).single
              as OverlayNote;
      expect((shape.x, shape.y, shape.text), (0.4, 0.5, 'hi'));
    });

    test('a fading mark is painted with its faded strength, then dropped', () {
      final half = _t0.add(annotationHold + annotationFade * 0.5);
      expect(shapesOf(_frame(), half).single.alpha, closeTo(0.5, 1e-9));
      expect(
        shapesOf(_frame(), _t0.add(annotationHold + annotationFade)),
        isEmpty,
      );
    });
  });

  group('overlayAccepts (opt-in gating)', () {
    bool accepts(
      api.CanvasScreenAnnotation f, {
      bool active = true,
      String? self = 'me',
      String? channel = 'call',
    }) => overlayAccepts(
      f,
      overlayActive: active,
      selfId: self,
      callChannelId: channel,
    );

    test('a mark over my shared screen is shown while the overlay is on', () {
      expect(accepts(_frame()), isTrue);
    });

    test('nothing is shown while the overlay is off', () {
      expect(accepts(_frame(), active: false), isFalse);
    });

    test('a mark over somebody else\'s screen is not mine to show', () {
      expect(accepts(_frame(target: 'other')), isFalse);
    });

    test('a mark from another channel is not shown', () {
      expect(accepts(_frame(channel: 'elsewhere')), isFalse);
    });

    test('consent frames are never marks', () {
      expect(accepts(_frame(kind: 'consent')), isFalse);
    });

    test('nothing is shown when I do not know who I am', () {
      expect(accepts(_frame(), self: null), isFalse);
    });
  });
}
