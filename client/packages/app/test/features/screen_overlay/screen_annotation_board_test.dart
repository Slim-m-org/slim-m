// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks viewers leave on a shared screen: how they accumulate, how long
/// they hold, and when they are gone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';

final _t0 = DateTime(2026, 10, 28, 12);

api.CanvasScreenAnnotation _frame({
  String kind = 'stroke',
  String id = 'a1',
  String user = 'viewer',
  List<double> points = const [0.1, 0.1],
  String? text,
  bool ended = false,
}) => api.CanvasScreenAnnotation(
  channelId: 'c',
  userId: user,
  targetUserId: 'sharer',
  kind: kind,
  annotationId: id,
  points: points,
  color: 'blue',
  text: text,
  ended: ended,
  allowed: false,
);

void main() {
  test('a stroke grows by its delta frames', () {
    final board = ScreenAnnotationBoard()
      ..apply(_frame(points: [0.1, 0.1, 0.2, 0.2]), _t0)
      ..apply(_frame(points: [0.3, 0.3]), _t0);
    expect(board.liveAt(_t0).single.points, [0.1, 0.1, 0.2, 0.2, 0.3, 0.3]);
  });

  test('a shape keeps only its latest ellipse', () {
    final board = ScreenAnnotationBoard()
      ..apply(_frame(kind: 'shape', points: [0.1, 0.1, 0.2, 0.2]), _t0)
      ..apply(_frame(kind: 'shape', points: [0.1, 0.1, 0.6, 0.5]), _t0);
    expect(board.liveAt(_t0).single.points, [0.1, 0.1, 0.6, 0.5]);
  });

  test('a finished stroke holds, then fades linearly, then is gone', () {
    final board = ScreenAnnotationBoard()..apply(_frame(ended: true), _t0);
    final mark = board.liveAt(_t0).single;
    expect(mark.alphaAt(_t0.add(annotationHold)), 1);
    final halfway = _t0.add(annotationHold + annotationFade * 0.5);
    expect(mark.alphaAt(halfway), closeTo(0.5, 1e-9));
    final gone = _t0.add(annotationHold + annotationFade);
    expect(mark.alphaAt(gone), 0);
    expect(board.liveAt(gone), isEmpty);
    expect(board.isEmpty, isTrue);
  });

  test('a stroke still being drawn does not fade', () {
    final board = ScreenAnnotationBoard()..apply(_frame(), _t0);
    final mark = board.liveAt(_t0).single;
    expect(mark.alphaAt(_t0.add(annotationStaleAfter)), 1);
  });

  test('a stroke whose last frame never came fades from its last frame', () {
    final board = ScreenAnnotationBoard()..apply(_frame(), _t0);
    final mark = board.liveAt(_t0).single;
    final quiet = _t0.add(annotationStaleAfter + const Duration(seconds: 1));
    expect(mark.alphaAt(quiet), 1);
    expect(mark.alphaAt(_t0.add(annotationHold + annotationFade)), 0);
    expect(board.liveAt(_t0.add(annotationHold + annotationFade)), isEmpty);
  });

  test('a note stays longer than ink', () {
    final board = ScreenAnnotationBoard()
      ..apply(
        _frame(
          kind: 'note',
          id: 'n',
          points: [0.4, 0.4],
          text: 'look',
          ended: true,
        ),
        _t0,
      );
    final mark = board.liveAt(_t0).single;
    expect(mark.text, 'look');
    expect(mark.alphaAt(_t0.add(annotationHold + annotationFade)), 1);
    expect(mark.alphaAt(_t0.add(annotationNoteHold + annotationFade)), 0);
  });

  test('another author cannot extend a mark that is not theirs', () {
    final board = ScreenAnnotationBoard()
      ..apply(_frame(points: [0.1, 0.1]), _t0)
      ..apply(_frame(user: 'intruder', points: [0.9, 0.9]), _t0);
    expect(board.liveAt(_t0).single.points, [0.1, 0.1]);
  });

  test('consent frames and unknown kinds are not marks', () {
    final board = ScreenAnnotationBoard()
      ..apply(_frame(kind: 'consent'), _t0)
      ..apply(_frame(kind: 'sparkle', id: 'x'), _t0);
    expect(board.isEmpty, isTrue);
  });

  test('the oldest mark is dropped past the cap', () {
    final board = ScreenAnnotationBoard();
    for (var i = 0; i <= maxLiveAnnotations; i++) {
      board.apply(_frame(id: 'm$i'), _t0);
    }
    final ids = board.liveAt(_t0).map((m) => m.id);
    expect(ids.length, maxLiveAnnotations);
    expect(ids, isNot(contains('m0')));
  });

  test('a stroke stops growing at its size cap', () {
    final board = ScreenAnnotationBoard();
    for (var i = 0; i < 200; i++) {
      board.apply(_frame(points: List.filled(24, 0.5)), _t0);
    }
    expect(
      board.liveAt(_t0).single.points.length,
      lessThanOrEqualTo(maxStrokeValues),
    );
  });
}
