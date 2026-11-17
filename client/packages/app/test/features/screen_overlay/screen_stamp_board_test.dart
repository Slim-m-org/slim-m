// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a stamp lives on a shared screen (decision 0121): its clock starts
/// when its picture is ready, it pops in, holds 8 seconds and fades, and the
/// caps start the oldest fading early.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_consent.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_stamp_timing.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';

import 'stamp_frames.dart';

final _t0 = DateTime(2026, 11, 16, 12);

void main() {
  test('a stamp keeps its centre, size and content', () {
    final board = ScreenAnnotationBoard()
      ..apply(stampFrame(attachment: 'abc', animated: true), _t0);
    final mark = board.liveAt(_t0).single;
    expect(mark.kind, ScreenAnnotationKind.stamp);
    expect(mark.points, [0.4, 0.3]);
    expect(mark.size, 0.12);
    expect(mark.stamp, const PictureStamp('abc', animated: true));
  });

  test('a stamp is invisible until it is ready, then holds 8 s and fades', () {
    final board = ScreenAnnotationBoard()..apply(stampFrame(), _t0);
    final mark = board.liveAt(_t0).single;
    expect(mark.alphaAt(_t0.add(const Duration(seconds: 2))), 0);

    final ready = _t0.add(const Duration(seconds: 2));
    expect(board.markReady('s1', ready), isTrue);
    expect(mark.alphaAt(ready), 1);
    expect(mark.alphaAt(ready.add(annotationStampHold)), 1);
    final halfway = ready.add(annotationStampHold + annotationFade * 0.5);
    expect(mark.alphaAt(halfway), closeTo(0.5, 1e-6));
    final gone = ready.add(annotationStampHold + annotationFade);
    expect(board.liveAt(gone), isEmpty);
  });

  test('a stamp whose picture never arrives is dropped after 5 s', () {
    final board = ScreenAnnotationBoard()..apply(stampFrame(), _t0);
    final late = _t0.add(annotationStampReadyWithin);
    expect(board.liveAt(late), hasLength(1));
    final past = late.add(const Duration(milliseconds: 1));
    expect(board.markReady('s1', past), isFalse);
    expect(board.liveAt(past), isEmpty);
  });

  test(
    'it pops in from 60% with an overshoot, or at once with reduced motion',
    () {
      expect(stampPopScale(Duration.zero), stampPopFrom);
      final mid = stampPopScale(annotationStampPop * 0.6);
      expect(mid, greaterThan(1));
      expect(stampPopScale(annotationStampPop), 1);
      expect(stampPopScale(Duration.zero, reduceMotion: true), 1);

      final board = ScreenAnnotationBoard()..apply(stampFrame(), _t0);
      final mark = board.liveAt(_t0).single;
      expect(mark.scaleAt(_t0), 1);
      board.markReady('s1', _t0);
      expect(mark.scaleAt(_t0), stampPopFrom);
      expect(mark.scaleAt(_t0, reduceMotion: true), 1);
    },
  );

  test('a repeat of a stamp id changes nothing', () {
    final board = ScreenAnnotationBoard()
      ..apply(stampFrame(), _t0)
      ..apply(stampFrame(points: const [0.9, 0.9], emoji: 'x'), _t0);
    expect(board.liveAt(_t0).single.points, [0.4, 0.3]);
    expect(board.liveAt(_t0).single.stamp, const EmojiStamp('\u{1F389}'));
  });

  test('a stamp with no content, size or centre is not a mark', () {
    final board = ScreenAnnotationBoard()
      ..apply(stampFrame(id: 'a', emoji: null), _t0)
      ..apply(stampFrame(id: 'b', size: null), _t0)
      ..apply(stampFrame(id: 'c', points: const [0.1]), _t0);
    expect(board.isEmpty, isTrue);
  });

  test('size and centre are held inside the screen and the server bounds', () {
    final board = ScreenAnnotationBoard()
      ..apply(stampFrame(points: const [1.4, -0.2], size: 0.9), _t0);
    final mark = board.liveAt(_t0).single;
    expect(mark.points, [1.0, 0.0]);
    expect(mark.size, stampMaxSize);
  });

  test('a fourth stamp from one person starts their oldest fading at once', () {
    final board = ScreenAnnotationBoard();
    for (var i = 1; i <= 3; i++) {
      board
        ..apply(stampFrame(id: 's$i'), _t0)
        ..markReady('s$i', _t0);
    }
    final later = _t0.add(const Duration(seconds: 1));
    board
      ..apply(stampFrame(id: 's4'), later)
      ..markReady('s4', later);
    final byId = {for (final m in board.liveAt(later)) m.id: m};
    expect(
      byId['s1']!.alphaAt(later.add(annotationFade * 0.5)),
      closeTo(0.5, 1e-6),
    );
    expect(byId['s2']!.alphaAt(later.add(annotationFade)), 1);
    expect(board.liveAt(later.add(annotationFade)).map((m) => m.id), [
      's2',
      's3',
      's4',
    ]);
  });

  test('another person\'s stamps do not count toward my three', () {
    final board = ScreenAnnotationBoard();
    for (var i = 1; i <= 3; i++) {
      board
        ..apply(stampFrame(id: 'a$i', user: 'ann'), _t0)
        ..markReady('a$i', _t0);
    }
    board
      ..apply(stampFrame(id: 'b1', user: 'bob'), _t0)
      ..markReady('b1', _t0);
    expect(board.liveAt(_t0).every((m) => m.holdingAt(_t0)), isTrue);
  });

  test('a stamp still loading when the cap passes it is simply dropped', () {
    final board = ScreenAnnotationBoard();
    for (var i = 1; i <= 4; i++) {
      board.apply(stampFrame(id: 's$i'), _t0);
    }
    expect(board.liveAt(_t0).map((m) => m.id), ['s2', 's3', 's4']);
  });

  test('one screen holds 12 live stamps from everyone together', () {
    final board = ScreenAnnotationBoard();
    for (var i = 0; i < 13; i++) {
      board
        ..apply(stampFrame(id: 's$i', user: 'u${i ~/ 3}'), _t0)
        ..markReady('s$i', _t0);
    }
    final holding = board.liveAt(_t0).where((m) => m.holdingAt(_t0));
    expect(holding, hasLength(maxStampsPerScreen));
    expect(holding.map((m) => m.id), isNot(contains('s0')));
  });

  test('remove takes a refused stamp off at once', () {
    final board = ScreenAnnotationBoard()..apply(stampFrame(), _t0);
    expect(board.remove('s1'), isTrue);
    expect(board.isEmpty, isTrue);
  });

  test('a sharer\'s consent says whether their client shows stamps', () {
    final consent = ScreenAnnotationConsent()
      ..apply(
        const api.CanvasScreenAnnotation(
          channelId: 'c',
          userId: 'old',
          targetUserId: 'old',
          kind: 'consent',
          points: [],
          ended: false,
          allowed: true,
        ),
        _t0,
      )
      ..apply(
        const api.CanvasScreenAnnotation(
          channelId: 'c',
          userId: 'new',
          targetUserId: 'new',
          kind: 'consent',
          points: [],
          ended: false,
          allowed: true,
          stamps: true,
        ),
        _t0,
      );
    expect(consent.of('old', _t0)!.stamps, isFalse);
    expect(consent.of('new', _t0)!.stamps, isTrue);
  });

  test('an emoji names its picture by glyph or custom id', () {
    const index = {'party': 'id-1'};
    expect(const EmojiStamp('\u{1F389}').imageKey(index), 'e:\u{1F389}');
    expect(const EmojiStamp(':tada:').imageKey(index), 'e:\u{1F389}');
    expect(const EmojiStamp(':party:').imageKey(index), 'c:id-1');
    expect(const PictureStamp('abc').imageKey(index), 'a:abc');
  });
}
