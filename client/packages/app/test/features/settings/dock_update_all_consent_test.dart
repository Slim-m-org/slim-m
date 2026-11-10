// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Update all asks about new access instead of failing on it.
///
/// The owner pressed Update all with two updates and got a red box, "Updated 1
/// of 2. Word Guess asks for new access. Open it to review.", while the module
/// kept its UPDATE chip. The consent step already existed for a single update;
/// the walk now opens it for each module that needs it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/dock_update_world.dart';

/// Taps outside the sheet or dialog, where the barrier is on both layouts.
Future<void> _tapBarrier(WidgetTester tester) async {
  await tester.tapAt(const Offset(8, 8));
  await settleDock(tester);
}

const _tick = 'I understand what this module can do';
const _approve = 'Approve and update';

/// The UPDATE badge on each module row still behind.
Finder get _updateChips => find.text('UPDATE');

void main() {
  eachDockUpdateSize('update all asks about new access instead of failing', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a'),
      const DockUpdateMod('b', asks: ['kv.store']),
    ]);
    await openDockUpdateWorld(tester, world, size);

    await tapDock(tester, 'Update all');

    expect(find.text('Update Mod b?'), findsOneWidget);
    expect(
      find.text('Can keep its own private data on your server.'),
      findsOneWidget,
    );
    expect(find.textContaining('Open it to review'), findsNothing);
    expect(find.text('Dismiss'), findsNothing);
    expect(world.installs, ['a']);
  });

  eachDockUpdateSize(
    'the module that needed nothing has landed while the prompt is open',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a'),
        const DockUpdateMod('b', asks: ['kv.store']),
      ]);
      await openDockUpdateWorld(tester, world, size);
      expect(_updateChips, findsNWidgets(2));

      await tapDock(tester, 'Update all');

      expect(_updateChips, findsOneWidget, reason: 'a is current, b waits');
      expect(find.text('Updating...'), findsOneWidget);
    },
  );

  eachDockUpdateSize(
    'approving installs the module with the access it was shown',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a'),
        const DockUpdateMod('b', asks: ['kv.store']),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, _approve);

      expect(world.installs, ['a', 'b']);
      expect(world.bodies.last['approved_host_capabilities'], ['kv.store']);
      expect(world.bodies.last['reviewed_digest'], 'digest-b');
      expect(_updateChips, findsNothing);
      expect(find.text('Update all'), findsNothing);
      expect(find.text('Dismiss'), findsNothing);
    },
  );

  eachDockUpdateSize(
    'skipping keeps the update and goes on to the next module',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', asks: ['kv.store']),
        const DockUpdateMod('b'),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Skip');

      expect(world.installs, [
        'b',
      ], reason: 'b still goes through after a skip');
      expect(_updateChips, findsOneWidget);
      expect(find.text('Updated 1 of 2. Skipped Mod a.'), findsOneWidget);
      expect(
        find.text('Dismiss'),
        findsNothing,
        reason: 'a skip is not an error',
      );
      expect(find.text('Update all'), findsOneWidget);
    },
  );

  eachDockUpdateSize(
    'closing the prompt counts as a skip for that module only',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', asks: ['kv.store']),
        const DockUpdateMod('b'),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text('Update Mod a?'), findsOneWidget);

      await _tapBarrier(tester);

      expect(find.text('Update Mod a?'), findsNothing);
      expect(world.installs, ['b']);
      expect(find.text('Updated 1 of 2. Skipped Mod a.'), findsOneWidget);
      expect(find.text('Dismiss'), findsNothing);
    },
  );

  eachDockUpdateSize('every module asking is asked in order', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', asks: ['kv.store']),
      const DockUpdateMod('b', asks: ['log.read']),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');
    expect(find.text('Update Mod a?'), findsOneWidget);

    await tapDock(tester, _approve);
    expect(find.text('Update Mod b?'), findsOneWidget);
    await tapDock(tester, _approve);

    expect(world.installs, ['a', 'b']);
    expect(_updateChips, findsNothing);
  });

  eachDockUpdateSize('a verified module is a lighter list with no tick', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', asks: ['kv.store']),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');

    expect(find.text(_tick), findsNothing);
    expect(
      find.text('Not verified. slim-m has not reviewed this module.'),
      findsNothing,
    );
    final approve = tester.widget<AppButton>(
      find.widgetWithText(AppButton, _approve),
    );
    expect(approve.disabled, isFalse);
  });

  eachDockUpdateSize(
    'an unreviewed module needs the tick before it can be approved',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', community: true, asks: ['kv.store']),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(
        find.text('Not verified. slim-m has not reviewed this module.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, _approve))
            .disabled,
        isTrue,
      );

      await tapDock(tester, _tick);
      await tapDock(tester, _approve);

      expect(world.installs, ['a']);
      expect(world.bodies.single['approved_host_capabilities'], ['kv.store']);
    },
  );

  eachDockUpdateSize(
    'access taken back by a new build is asked again, not reported',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['message.post'],
          approvedBefore: ['message.post'],
          newBuild: true,
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text('Update Mod a?'), findsOneWidget);
      expect(
        find.text('This version needs approval again. It can:'),
        findsOneWidget,
      );
      expect(world.installs, isEmpty, reason: 'nothing is taken back unasked');

      await tapDock(tester, _approve);

      expect(world.bodies.single['approved_host_capabilities'], [
        'message.post',
      ]);
      expect(_updateChips, findsNothing);
      expect(find.text('Dismiss'), findsNothing);
    },
  );

  eachDockUpdateSize(
    'skipping a re-approval leaves the module on its old build',
    (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['message.post'],
          approvedBefore: ['message.post'],
          newBuild: true,
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Skip');

      expect(world.installs, isEmpty);
      expect(_updateChips, findsOneWidget);
    },
  );

  eachDockUpdateSize('access that is kept carries over without a prompt', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod(
        'a',
        asks: ['kv.store'],
        approvedBefore: ['kv.store'],
      ),
    ]);
    await openDockUpdateWorld(tester, world, size);

    await tapDock(tester, 'Update all');

    expect(find.text('Update Mod a?'), findsNothing);
    expect(world.installs, ['a']);
    expect(
      world.bodies.single.containsKey('approved_host_capabilities'),
      isFalse,
      reason: 'the server carries what was approved; a list would replace it',
    );
  });

  eachDockUpdateSize('a failed install is an inline error with the reason', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', refuse: true),
      const DockUpdateMod('b'),
    ]);
    await openDockUpdateWorld(tester, world, size);

    await tapDock(tester, 'Update all');

    expect(world.installs, ['b']);
    expect(find.text('Could not update Mod a. Moved on.'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.text('Updated 1 of 2.'), findsOneWidget);
  });

  eachDockUpdateSize('a failure after an approval is still an inline error', (
    tester,
    size,
  ) async {
    final world = DockUpdateWorld([
      const DockUpdateMod('a', asks: ['kv.store'], refuse: true),
    ]);
    await openDockUpdateWorld(tester, world, size);
    await tapDock(tester, 'Update all');

    await tapDock(tester, _approve);

    expect(find.text('Could not update Mod a. Moved on.'), findsOneWidget);
    expect(_updateChips, findsOneWidget);
  });
}
