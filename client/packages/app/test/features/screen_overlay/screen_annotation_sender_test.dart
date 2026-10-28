// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The relay frames one viewer gesture turns into: throttled deltas for ink,
/// the latest ellipse for a circle, one frame for a note.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_sender.dart';

void main() {
  late List<api.CanvasScreenAnnotation> sent;
  late ScreenAnnotationSender sender;

  setUp(() {
    sent = [];
    sender = ScreenAnnotationSender(
      channelId: 'call',
      sharerId: 'sharer',
      selfId: 'me',
      colorKey: 'blue',
      emit: sent.add,
    );
  });

  tearDown(() => sender.dispose());

  testWidgets('a stroke goes out as deltas and ends with an ended frame', (
    tester,
  ) async {
    sender.beginStroke(const Offset(0.1, 0.1));
    sender.extendStroke(const Offset(0.2, 0.2));
    await tester.pump(annotationFlushInterval);
    expect(sent.single.points, [0.1, 0.1, 0.2, 0.2]);
    expect(sent.single.ended, isFalse);

    sender.extendStroke(const Offset(0.3, 0.3));
    sender.endStroke();
    expect(sent.last.points, [0.3, 0.3]);
    expect(sent.last.ended, isTrue);
    expect(sent.map((f) => f.annotationId).toSet(), hasLength(1));
    expect(
      sent.every((f) => f.targetUserId == 'sharer' && f.userId == 'me'),
      isTrue,
    );
    expect(sent.every((f) => f.color == 'blue' && f.kind == 'stroke'), isTrue);
  });

  testWidgets('a flush with nothing new sends nothing', (tester) async {
    sender.beginStroke(const Offset(0.1, 0.1));
    await tester.pump(annotationFlushInterval);
    await tester.pump(annotationFlushInterval);
    expect(sent, hasLength(1));
    sender.dispose();
  });

  testWidgets(
    'a long run between flushes is thinned to the frame cap, keeping the end',
    (tester) async {
      sender.beginStroke(Offset.zero);
      for (var i = 1; i <= 100; i++) {
        sender.extendStroke(Offset(i / 100, i / 100));
      }
      await tester.pump(annotationFlushInterval);
      final points = sent.single.points;
      expect(points.length, maxPairsPerFrame * 2);
      expect(points.take(2), [0.0, 0.0]);
      expect(points.skip(points.length - 2), [1.0, 1.0]);
      sender.dispose();
    },
  );

  testWidgets('a circle sends its latest ellipse, then ends', (tester) async {
    sender.dragShape(const Offset(0.1, 0.1), const Offset(0.4, 0.4));
    sender.dragShape(const Offset(0.1, 0.1), const Offset(0.6, 0.5));
    await tester.pump(annotationFlushInterval);
    expect(sent.single.kind, 'shape');
    expect(sent.single.points, [0.1, 0.1, 0.6, 0.5]);

    sender.endShape();
    expect(sent.last.ended, isTrue);
    expect(sent.last.points, [0.1, 0.1, 0.6, 0.5]);
  });

  test('a note is one finished frame with its trimmed text', () {
    sender.note(const Offset(0.4, 0.5), '  look here  ');
    expect(sent.single.kind, 'note');
    expect(sent.single.text, 'look here');
    expect(sent.single.points, [0.4, 0.5]);
    expect(sent.single.ended, isTrue);
  });

  test('a blank note is not sent', () {
    sender.note(const Offset(0.4, 0.5), '   ');
    expect(sent, isEmpty);
  });

  test('each mark gets its own id', () {
    sender.note(const Offset(0.1, 0.1), 'a');
    sender.note(const Offset(0.2, 0.2), 'b');
    expect(sent.map((f) => f.annotationId).toSet(), hasLength(2));
  });

  testWidgets('abandoning a stroke mid-way still ends it', (tester) async {
    sender.beginStroke(const Offset(0.1, 0.1));
    sender.dispose();
    expect(sent.last.ended, isTrue);
  });
}
