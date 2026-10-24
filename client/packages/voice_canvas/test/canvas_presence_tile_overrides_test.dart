// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasPresenceTileOverrides]: default state, that each mutator both
/// stores its own field and leaves the others untouched, that [prune] drops
/// only [CanvasPresenceTileState.hidden] for a key that left the roster
/// while position, lock and depth survive it, and that every mutation
/// notifies.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('an unset key defaults to no rect, unlocked, not hidden, in front', () {
    final overrides = CanvasPresenceTileOverrides();

    final state = overrides.stateFor('camera:alice');

    expect(state.rect, isNull);
    expect(state.locked, isFalse);
    expect(state.hidden, isFalse);
    expect(state.sentToBack, isFalse);
  });

  test('setRect stores a rect for its own key only', () {
    final overrides = CanvasPresenceTileOverrides();

    overrides.setRect('camera:alice', const Rect.fromLTWH(10, 20, 30, 40));

    expect(overrides.stateFor('camera:alice').rect,
        const Rect.fromLTWH(10, 20, 30, 40));
    expect(overrides.stateFor('camera:bob').rect, isNull);
  });

  test('setLocked does not touch a rect already recorded', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(1, 2, 3, 4));

    overrides.setLocked('camera:alice', true);

    final state = overrides.stateFor('camera:alice');
    expect(state.locked, isTrue);
    expect(state.rect, const Rect.fromLTWH(1, 2, 3, 4));
  });

  test('setSentToBack does not touch locked, hidden or rect', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(1, 2, 3, 4));
    overrides.setLocked('camera:alice', true);

    overrides.setSentToBack('camera:alice', true);

    final state = overrides.stateFor('camera:alice');
    expect(state.sentToBack, isTrue);
    expect(state.locked, isTrue);
    expect(state.rect, const Rect.fromLTWH(1, 2, 3, 4));
  });

  test('setSentToBack(false) reverses it, leaving everything else alone', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setSentToBack('camera:alice', true);

    overrides.setSentToBack('camera:alice', false);

    expect(overrides.stateFor('camera:alice').sentToBack, isFalse);
  });

  test('setHidden does not touch locked, rect or sentToBack', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(1, 2, 3, 4));
    overrides.setLocked('camera:alice', true);
    overrides.setSentToBack('camera:alice', true);

    overrides.setHidden('camera:alice', true);

    final state = overrides.stateFor('camera:alice');
    expect(state.hidden, isTrue);
    expect(state.locked, isTrue);
    expect(state.sentToBack, isTrue);
    expect(state.rect, const Rect.fromLTWH(1, 2, 3, 4));
  });

  test('applyServer replaces rect, locked and sentToBack but not hidden', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setHidden('camera:alice', true);

    overrides.applyServer(
      'camera:alice',
      rect: const Rect.fromLTWH(1, 2, 3, 4),
      locked: true,
      sentToBack: true,
    );

    final state = overrides.stateFor('camera:alice');
    expect(state.rect, const Rect.fromLTWH(1, 2, 3, 4));
    expect(state.locked, isTrue);
    expect(state.sentToBack, isTrue);
    expect(state.hidden, isTrue, reason: 'hidden is never shared');
  });

  test('hiddenKeys names exactly the keys marked hidden', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setHidden('camera:alice', true);
    overrides.setHidden('screen:alice', true);
    overrides.setLocked('camera:bob', true);

    expect(overrides.hiddenKeys.toSet(), {'camera:alice', 'screen:alice'});
  });

  test(
      'prune leaves rect, locked and sentToBack alone for a key that left '
      'the roster - they are shared and persistent now, not reset on '
      'rejoin', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(1, 2, 3, 4));
    overrides.setLocked('camera:alice', true);
    overrides.setSentToBack('camera:alice', true);

    overrides.prune(const {});

    final state = overrides.stateFor('camera:alice');
    expect(state.rect, const Rect.fromLTWH(1, 2, 3, 4));
    expect(state.locked, isTrue);
    expect(state.sentToBack, isTrue);
  });

  test('prune drops hidden for a key that left the roster', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setHidden('camera:alice', true);

    overrides.prune(const {});

    expect(overrides.stateFor('camera:alice').hidden, isFalse);
  });

  test('prune leaves hidden alone for a key still in the roster', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setHidden('camera:alice', true);

    overrides.prune({'camera:alice'});

    expect(overrides.stateFor('camera:alice').hidden, isTrue);
  });

  test('prune with nothing to drop does not notify', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(1, 2, 3, 4));
    var notifications = 0;
    overrides.addListener(() => notifications++);

    overrides.prune({'camera:alice'});

    expect(notifications, 0);
  });

  test(
      'a key is untouched until its rect is set, and setRect ranks keys by '
      'when they were last touched', () {
    final overrides = CanvasPresenceTileOverrides();
    expect(overrides.zFor('camera:alice'), isNull);

    overrides.setRect('camera:alice', const Rect.fromLTWH(0, 0, 10, 10));
    overrides.setRect('camera:bob', const Rect.fromLTWH(0, 0, 10, 10));

    expect(overrides.zFor('camera:alice'),
        lessThan(overrides.zFor('camera:bob')!));
  });

  test('touching a key again moves it to the front of the touch order', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(0, 0, 10, 10));
    overrides.setRect('camera:bob', const Rect.fromLTWH(0, 0, 10, 10));

    overrides.setRect('camera:alice', const Rect.fromLTWH(5, 5, 10, 10));

    expect(overrides.zFor('camera:alice'),
        greaterThan(overrides.zFor('camera:bob')!));
  });

  test('the server answers set the order, so a local drag does not outrank it',
      () {
    final overrides = CanvasPresenceTileOverrides();
    const rect = Rect.fromLTWH(0, 0, 10, 10);
    overrides.setRect('camera:alice', rect);
    overrides.applyServer('camera:bob',
        rect: rect, locked: false, sentToBack: false);
    overrides.applyServer('camera:alice',
        rect: rect, locked: false, sentToBack: false);

    expect(overrides.zFor('camera:alice'),
        greaterThan(overrides.zFor('camera:bob')!));
  });

  test('prune keeps the stacking of a saved slot whose feed is off', () {
    final overrides = CanvasPresenceTileOverrides();
    overrides.setRect('camera:alice', const Rect.fromLTWH(0, 0, 10, 10));
    overrides.setRect('camera:bob', const Rect.fromLTWH(0, 0, 10, 10));
    final alice = overrides.zFor('camera:alice');
    final bob = overrides.zFor('camera:bob');

    overrides.prune(const {});

    expect(overrides.zFor('camera:alice'), alice);
    expect(overrides.zFor('camera:bob'), bob);
    expect(overrides.sharedRectFor('camera:alice'), isNotNull);
  });

  test('slots fetched before their feeds start keep the server order', () {
    final overrides = CanvasPresenceTileOverrides();
    const rect = Rect.fromLTWH(0, 0, 10, 10);
    overrides.applyServer('screen:alice',
        rect: rect, locked: false, sentToBack: false);
    overrides.applyServer('camera:bob',
        rect: rect, locked: false, sentToBack: false);

    overrides.prune({'camera:carol'});

    expect(overrides.zFor('screen:alice'),
        lessThan(overrides.zFor('camera:bob')!));
  });

  test(
      'setRect clamps a position far past the bounded world, the same '
      'limit the camera itself is already held to', () {
    final overrides = CanvasPresenceTileOverrides();

    overrides.setRect(
      'camera:alice',
      const Rect.fromLTWH(50000000, -50000000, 140, 140),
    );

    final rect = overrides.stateFor('camera:alice').rect!;
    expect(rect.left, lessThanOrEqualTo(worldLimit));
    expect(rect.top, greaterThanOrEqualTo(-worldLimit));
    expect(rect.width, 140, reason: 'clamping moves a tile, never resizes it');
    expect(rect.height, 140);
  });

  test('every mutator notifies listeners exactly once', () {
    final overrides = CanvasPresenceTileOverrides();
    var notifications = 0;
    overrides.addListener(() => notifications++);

    overrides.setRect('camera:alice', const Rect.fromLTWH(1, 2, 3, 4));
    overrides.setLocked('camera:alice', true);
    overrides.setSentToBack('camera:alice', true);
    overrides.setHidden('camera:alice', true);
    overrides.applyServer(
      'camera:alice',
      rect: const Rect.fromLTWH(5, 6, 7, 8),
      locked: false,
      sentToBack: false,
    );
    overrides.prune(const {});

    expect(notifications, 6);
  });
}
