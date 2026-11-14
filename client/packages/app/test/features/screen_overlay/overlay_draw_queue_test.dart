// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overlay's frame hand-off: a frame that repeats the last is not sent,
/// and a slow window never has more than one draw out and one waiting.
library;

import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/overlay_draw_queue.dart';
import 'package:slimm_platform/platform.dart';

class _SlowOverlay implements ScreenOverlay {
  final draws = <List<OverlayShape>>[];
  final _replies = <Completer<void>>[];

  @override
  Future<void> draw(List<OverlayShape> shapes) {
    draws.add(shapes);
    final reply = Completer<void>();
    _replies.add(reply);
    return reply.future;
  }

  Future<void> answer() async {
    _replies.removeAt(0).complete();
    await pumpEventQueue();
  }

  int get outstanding => _replies.length;

  @override
  Future<OverlaySupport> support() async => const OverlaySupport.unsupported();
  @override
  Future<bool> show(List<int> monitors, {int? window}) async => true;
  @override
  Future<void> hide() async {}
  @override
  Future<void> panel(OverlayPanel? panel) async {}
  @override
  Future<int?> appMonitor() async => null;
}

OverlayShape _stroke(double end, {double alpha = 1}) => OverlayStroke(
  points: [0.1, 0.1, end, end],
  color: const Color(0xFF5B8FD6),
  alpha: alpha,
);

void main() {
  late _SlowOverlay window;
  late OverlayDrawQueue queue;

  setUp(() {
    window = _SlowOverlay();
    queue = OverlayDrawQueue(window);
  });

  test('a blank overlay is not told to draw nothing', () {
    queue.draw(const []);
    expect(window.draws, isEmpty);
  });

  test('a frame that repeats the last one is not sent again', () async {
    queue.draw([_stroke(0.5)]);
    await window.answer();
    queue.draw([_stroke(0.5)]);
    queue.draw([_stroke(0.5)]);
    expect(window.draws, hasLength(1));
  });

  test('a fading frame is sent each time its strength changes', () async {
    queue.draw([_stroke(0.5)]);
    await window.answer();
    queue.draw([_stroke(0.5, alpha: 0.8)]);
    await window.answer();
    queue.draw([_stroke(0.5, alpha: 0.4)]);
    expect(window.draws, hasLength(3));
  });

  test('clearing the overlay is sent once', () async {
    queue.draw([_stroke(0.5)]);
    await window.answer();
    queue.draw(const []);
    await window.answer();
    queue.draw(const []);
    expect(window.draws, hasLength(2));
    expect(window.draws.last, isEmpty);
  });

  test('while a draw is out only the newest frame waits behind it', () async {
    queue.draw([_stroke(0.2)]);
    queue.draw([_stroke(0.3)]);
    queue.draw([_stroke(0.4)]);
    expect(window.outstanding, 1);

    await window.answer();
    expect(window.draws, hasLength(2));
    expect(window.draws.last, [_stroke(0.4)]);
    expect(window.outstanding, 1);

    await window.answer();
    expect(window.draws, hasLength(2));
    expect(window.outstanding, 0);
  });

  test('a waiting frame equal to what the window shows is dropped', () async {
    queue.draw([_stroke(0.2)]);
    queue.draw([_stroke(0.3)]);
    queue.draw([_stroke(0.2)]);
    await window.answer();
    expect(window.draws, hasLength(1));
    expect(window.outstanding, 0);
  });

  test(
    'a shown or hidden window is blank, so the next frame is sent',
    () async {
      queue.draw([_stroke(0.5)]);
      await window.answer();
      queue.reset();
      queue.draw([_stroke(0.5)]);
      expect(window.draws, hasLength(2));
      await window.answer();

      queue.reset();
      queue.draw(const []);
      expect(window.draws, hasLength(2));
    },
  );

  test('a reset drops the frame that was waiting', () async {
    queue.draw([_stroke(0.2)]);
    queue.draw([_stroke(0.3)]);
    queue.reset();
    await window.answer();
    expect(window.draws, hasLength(1));
    expect(window.outstanding, 0);
  });
}
