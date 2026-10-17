// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Selecting several messages, and the two rules that are easy to get wrong.
///
/// The cap is one: a selection that has reached 64 must still let go of a
/// message, or picking one too many strands the user with no way back except
/// abandoning the whole selection. The other is that selection mode outlives
/// an empty selection, so deselecting the last message does not close the bar
/// mid-decision.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_selection.dart';

MessageSelectionController controller() => MessageSelectionController();

void main() {
  test('nothing is selected, and the mode is off, to begin with', () {
    final c = controller();
    expect(c.state.active, isFalse);
    expect(c.state.count, 0);
  });

  test('starting selects the message it started from', () {
    final c = controller()..start('m1');
    expect(c.state.active, isTrue);
    expect(c.state.contains('m1'), isTrue);
    expect(c.state.count, 1);
  });

  test('toggling adds, and toggling again removes', () {
    final c = controller()..start('m1');
    c.toggle('m2');
    expect(c.state.count, 2);
    c.toggle('m2');
    expect(c.state.contains('m2'), isFalse);
    expect(c.state.count, 1);
  });

  test('toggling does nothing at all while the mode is off', () {
    final c = controller()..toggle('m1');
    expect(
      c.state.active,
      isFalse,
      reason: 'an ordinary tap on a message must not silently begin selecting',
    );
    expect(c.state.count, 0);
  });

  test('cancelling ends the mode and forgets the selection', () {
    final c = controller()..start('m1');
    c.toggle('m2');
    c.clear();
    expect(c.state.active, isFalse);
    expect(c.state.count, 0);
  });

  test('deselecting the last message leaves the mode running', () {
    final c = controller()..start('m1');
    c.toggle('m1');
    expect(c.state.count, 0);
    expect(
      c.state.active,
      isTrue,
      reason:
          'the bar stays open to be cancelled deliberately, rather than '
          'vanishing under somebody who is still choosing',
    );
  });

  group('the cap', () {
    MessageSelectionController full() {
      final c = controller()..start('m0');
      for (var i = 1; i < maxBulkDeleteIds; i++) {
        c.toggle('m$i');
      }
      return c;
    }

    test('fills to exactly the server cap', () {
      final c = full();
      expect(c.state.count, maxBulkDeleteIds);
      expect(c.state.atCap, isTrue);
    });

    test('refuses one more rather than sending a request that would 400', () {
      final c = full();
      c.toggle('one-too-many');
      expect(c.state.count, maxBulkDeleteIds);
      expect(c.state.contains('one-too-many'), isFalse);
    });

    /// The rule the cap is most likely to break.
    test('still lets go of a message while full', () {
      final c = full();
      c.toggle('m0');
      expect(
        c.state.contains('m0'),
        isFalse,
        reason: 'a full selection that cannot be undone strands the user',
      );
      expect(c.state.atCap, isFalse);
      c.toggle('room-now');
      expect(
        c.state.contains('room-now'),
        isTrue,
        reason: 'and letting go must genuinely make room again',
      );
    });
  });

  test('the previous state is not mutated behind the caller', () {
    final c = controller()..start('m1');
    final before = c.state;
    c.toggle('m2');
    expect(
      before.count,
      1,
      reason: 'a widget holding the old value must not see it change under it',
    );
  });

  group('extending with shift', () {
    const order = ['m1', 'm2', 'm3', 'm4', 'm5'];

    test('a shift-tap selects everything from the anchor to the target', () {
      final c = controller()..start('m2');
      c.extendTo('m4', order);
      expect(c.state.ids, {'m2', 'm3', 'm4'});
    });

    test('and works upwards just as well', () {
      final c = controller()..start('m4');
      c.extendTo('m2', order);
      expect(c.state.ids, {'m2', 'm3', 'm4'});
    });

    test('it extends an unrelated selection, never replaces it', () {
      final c = controller()..start('m5');
      c.toggle('m1');
      c.extendTo('m3', order);
      expect(c.state.ids, {'m1', 'm2', 'm3', 'm5'});
    });

    test('the anchor is the last plain tap, and a shift-tap keeps it', () {
      final c = controller()..start('m1');
      c.toggle('m3');
      expect(c.state.anchor, 'm3');
      c.extendTo('m5', order);
      expect(
        c.state.anchor,
        'm3',
        reason: 'a second shift-tap re-extends from the same place',
      );
      c.extendTo('m2', order);
      expect(c.state.ids, {'m1', 'm2', 'm3', 'm4', 'm5'});
    });

    test('with no anchor in the transcript a shift-tap is a plain tap', () {
      final c = controller()..start('elsewhere');
      c.extendTo('m2', order);
      expect(c.state.ids, {'elsewhere', 'm2'});
    });

    test('the cap fills from the anchor outward and leaves no gap', () {
      final wide = [for (var i = 0; i < 100; i++) 'm$i'];
      final c = controller()..start('m0');
      c.extendTo('m99', wide);
      expect(c.state.count, maxBulkDeleteIds);
      expect(c.state.ids, wide.take(maxBulkDeleteIds).toSet());
    });

    test('nothing happens while the mode is off', () {
      final c = controller()..extendTo('m2', order);
      expect(c.state.active, isFalse);
      expect(c.state.count, 0);
    });
  });
}
