// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Update all brings Administrator connectors forward after one password prompt.
///
/// A connector holding Administrator outlives every password change, so its
/// install asks for the admin's password. The walk asks once, uses the answer
/// for every such connector in the run, and a dismissed prompt skips only them.
library;

import 'package:flutter_test/flutter_test.dart';

import '../../support/dock_update_world.dart';

const _admin = 1;
const _noAdmin = 1 << 4;
const _prompt = 'Confirm with your password';

Finder get _password => find.bySemanticsLabel('Your password');

Future<void> _type(WidgetTester tester, String value) async {
  await tester.enterText(_password, value);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await tapDock(tester, 'Update');
}

Future<void> _dismiss(WidgetTester tester) async {
  await tester.tapAt(const Offset(8, 8));
  await settleDock(tester);
}

void main() {
  eachDockUpdateSize('one prompt covers every administrator connector', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', connector: _admin),
      const DockUpdateMod('b', connector: _admin | _noAdmin),
      const DockUpdateMod('c'),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');

    expect(find.text(_prompt), findsOneWidget);
    await _type(tester, DockUpdateWorld.adminPassword);
    await _submit(tester);

    expect(
      find.text(_prompt),
      findsNothing,
      reason: 'asked once, not per module',
    );
    expect(world.installs, ['a', 'b', 'c']);
    expect(world.passwordAttempts, [
      DockUpdateWorld.adminPassword,
      DockUpdateWorld.adminPassword,
    ]);
    expect(find.textContaining('Updated'), findsNothing);
  });

  eachDockUpdateSize('dismissing the prompt skips only the administrators', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', connector: _admin),
      const DockUpdateMod('b', connector: _admin),
      const DockUpdateMod('c', connector: _noAdmin),
      const DockUpdateMod('d'),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');
    expect(find.text(_prompt), findsOneWidget);

    await _dismiss(tester);

    expect(find.text(_prompt), findsNothing, reason: 'b does not ask again');
    expect(world.installs, ['c', 'd']);
    expect(find.textContaining('Updated 2 of 4'), findsOneWidget);
    expect(
      find.textContaining('Mod a, Mod b need your password'),
      findsOneWidget,
    );
  });

  eachDockUpdateSize('a wrong password shows inline and a retry works', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', connector: _admin),
      const DockUpdateMod('b', connector: _admin),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');

    await _type(tester, 'nope');
    await _submit(tester);

    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(find.text(_prompt), findsOneWidget, reason: 'the sheet stays open');
    expect(world.installs, isEmpty);

    await _type(tester, DockUpdateWorld.adminPassword);
    await _submit(tester);

    expect(find.text(_prompt), findsNothing);
    expect(world.installs, ['a', 'b']);
  });

  eachDockUpdateSize('no administrator connector means no prompt', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', connector: _noAdmin),
      const DockUpdateMod('b'),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');

    expect(find.text(_prompt), findsNothing);
    expect(world.installs, ['a', 'b']);
    expect(world.passwordAttempts, isEmpty);
  });
}
