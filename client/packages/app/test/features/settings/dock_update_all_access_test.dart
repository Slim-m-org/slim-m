// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Update all gives a module only the access the admin was shown, and keeps the
/// list true to the server however an install ends.
///
/// The private-network yes is a separate approval (decision 0067), so a prompt
/// that does not show it must not grant it. An install can commit and still
/// answer with an error, so the list is read again after every attempt.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_host_access_card.dart';

import '../../support/dock_update_world.dart';

const _approve = 'Approve and update';
const _host = 'api.example.com';
const _privateNetworkOff =
    "Private network access turns off. Turn it back on from the module's page.";

DockUpdateMod _withdrawn({
  List<String> asks = const ['kv.store'],
  int? failAfterInstalls,
  bool localBefore = false,
}) => DockUpdateMod(
  'a',
  asks: asks,
  approvedBefore: asks,
  dropsOnCarry: asks,
  hosts: asks.contains('net.fetch') ? const [_host] : const [],
  local: localBefore,
  localBefore: localBefore,
  failAfterInstalls: failAfterInstalls,
);

void main() {
  group('the private network', () {
    eachDockUpdateSize('is not granted by a prompt that asks about net.fetch', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['net.fetch'],
          approvedBefore: ['net.fetch'],
          newBuild: true,
          hosts: [_host],
          local: true,
          localBefore: true,
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text('Update Mod a?'), findsOneWidget);
      expect(find.text(dockLocalNetworkWarning), findsNothing);
      expect(find.text(_privateNetworkOff), findsOneWidget);

      await tapDock(tester, _approve);

      expect(world.bodies.single['approved_host_capabilities'], ['net.fetch']);
      expect(world.bodies.single['approve_local_network'], isFalse);
      expect(world.installed['a']!['local_network_approved'], isFalse);
    });

    eachDockUpdateSize('carries over while net.fetch itself carries over', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['net.fetch', 'kv.store'],
          approvedBefore: ['net.fetch'],
          hosts: [_host],
          local: true,
          localBefore: true,
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text('Update Mod a?'), findsOneWidget);
      expect(find.text(_privateNetworkOff), findsNothing);

      await tapDock(tester, _approve);

      expect(world.bodies.single['approve_local_network'], isTrue);
    });

    eachDockUpdateSize('is not mentioned when it was never approved', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['net.fetch'],
          approvedBefore: ['net.fetch'],
          newBuild: true,
          hosts: [_host],
          local: true,
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text('Update Mod a?'), findsOneWidget);
      expect(find.text(_privateNetworkOff), findsNothing);
    });

    eachDockUpdateSize('is not mentioned when the update no longer asks', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['net.fetch'],
          approvedBefore: ['net.fetch'],
          newBuild: true,
          hosts: [_host],
          localBefore: true,
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text('Update Mod a?'), findsOneWidget);
      expect(find.text(_privateNetworkOff), findsNothing);
    });

    eachDockUpdateSize('is mentioned again when the update took net.fetch', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        _withdrawn(asks: ['net.fetch'], localBefore: true),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text('Mod a is updated. Give back its access?'), findsOne);
      expect(find.text(_privateNetworkOff), findsOneWidget);
    });

    eachDockUpdateSize('is not given back with access the server withdrew', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        _withdrawn(asks: ['net.fetch'], localBefore: true),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Give access back');

      expect(world.installs, ['a', 'a']);
      expect(world.bodies.last['approved_host_capabilities'], ['net.fetch']);
      expect(world.bodies.last['approve_local_network'], isFalse);
    });
  });

  group('the module list', () {
    eachDockUpdateSize(
      'is read again after an install that committed then failed',
      (tester, size) async {
        final world = DockUpdateWorld([
          const DockUpdateMod('a', failAfterInstalls: 0),
          const DockUpdateMod('b', asks: ['kv.store']),
        ]);
        await openDockUpdateWorld(tester, world, size);
        expect(find.text('UPDATE'), findsNWidgets(2));

        await tapDock(tester, 'Update all');

        expect(find.text('Update Mod b?'), findsOneWidget);
        expect(world.installed['a']!['version'], '2.0.0');
        expect(find.text('UPDATE'), findsOneWidget, reason: 'a is current');
      },
    );

    eachDockUpdateSize('is read again after a failed re-install', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([_withdrawn(failAfterInstalls: 1)]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Give access back');

      expect(world.installed['a']!['version'], '2.0.0');
      expect(find.text('UPDATE'), findsNothing, reason: 'a is current');
      expect(find.textContaining('Could not'), findsOneWidget);
    });

    eachDockUpdateSize('is read again when the walk ends in a skip', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', asks: ['kv.store']),
      ]);
      await openDockUpdateWorld(tester, world, size);
      final before = world.catalogReads;
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Skip');

      expect(world.installs, isEmpty);
      expect(world.catalogReads, greaterThan(before));
    });
  });

  group('access the server withdrew after the update', () {
    eachDockUpdateSize('is asked about as an update that already happened', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([_withdrawn()]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text('Mod a is updated. Give back its access?'), findsOne);
      expect(find.text('The update took this access back. It can:'), findsOne);
      expect(find.text('Update Mod a?'), findsNothing);
      expect(find.text('Skip'), findsNothing);
      expect(find.text('Leave it off'), findsOneWidget);
    });

    eachDockUpdateSize('is given back when the admin agrees', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([_withdrawn()]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Give access back');

      expect(world.installs, ['a', 'a']);
      expect(world.bodies.last['approved_host_capabilities'], ['kv.store']);
      expect(find.text('Dismiss'), findsNothing);
    });

    eachDockUpdateSize('says the module was updated without it when declined', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([_withdrawn()]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      await tapDock(tester, 'Leave it off');

      expect(world.installs, ['a']);
      expect(find.text('UPDATE'), findsNothing);
      expect(
        find.text(
          'Updated 1 of 1. Mod a was updated without the access it had.',
        ),
        findsOneWidget,
      );
      expect(find.text('Dismiss'), findsNothing);
    });
  });
}
