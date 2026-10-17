// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Selecting several members, and the rules that are easy to get wrong.
///
/// The same two the message selection keeps - a full selection must still let
/// go, and the mode outlives an empty selection - plus the one this half adds:
/// entering from the pane header selects nobody, because the affordance is
/// about the list rather than about a member.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/member_selection.dart';

MemberSelectionController controller() => MemberSelectionController();

void main() {
  test('nothing is selected, and the mode is off, to begin with', () {
    final c = controller();
    expect(c.state.active, isFalse);
    expect(c.state.count, 0);
  });

  test('entering turns the mode on with nobody selected', () {
    final c = controller()..enter();
    expect(c.state.active, isTrue);
    expect(c.state.count, 0);
  });

  test('starting selects the member it started from', () {
    final c = controller()..start('u1');
    expect(c.state.active, isTrue);
    expect(c.state.contains('u1'), isTrue);
  });

  test('toggling adds, and toggling again removes', () {
    final c = controller()..enter();
    c.toggle('u1');
    expect(c.state.count, 1);
    c.toggle('u1');
    expect(c.state.count, 0);
    // Still on: deselecting the last member must not close the bar.
    expect(c.state.active, isTrue);
  });

  test('toggling does nothing at all while the mode is off', () {
    final c = controller()..toggle('u1');
    expect(c.state.active, isFalse);
    expect(c.state.count, 0);
  });

  test('the cap stops adding but never stops removing', () {
    final c = controller()..enter();
    for (var i = 0; i < maxBulkMemberIds; i++) {
      c.toggle('u$i');
    }
    expect(c.state.count, maxBulkMemberIds);
    expect(c.state.atCap, isTrue);

    c.toggle('one-too-many');
    expect(c.state.count, maxBulkMemberIds);
    expect(c.state.contains('one-too-many'), isFalse);

    // The way back out of a full selection, without abandoning all of it.
    c.toggle('u0');
    expect(c.state.count, maxBulkMemberIds - 1);
    expect(c.state.atCap, isFalse);
  });

  test('clearing ends the mode and forgets everything', () {
    final c = controller()..start('u1');
    c.toggle('u2');
    c.clear();
    expect(c.state.active, isFalse);
    expect(c.state.count, 0);
  });

  test('the cap matches the server, which refuses a longer list', () {
    expect(maxBulkMemberIds, 64);
  });
}
