// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Update all keeps or grants only access the admin was shown.
///
/// Three ways a power could ride along unseen: a record read before the admin
/// waited on a step, a capability this client cannot describe, and a hook that
/// widened without a new build.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_host_access_card.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_install_consent.dart';

import '../../dock_manifest_fixture.dart';
import '../../support/dock_update_world.dart';

const _approve = 'Approve and update';

void _revokeHostAccess(DockUpdateWorld world, String id) {
  world.installed[id]!['approved_host_capabilities'] = <String>[];
}

api.InstalledDockModule _installed(String version) => api.InstalledDockModule(
  id: 'm',
  name: 'm',
  version: version,
  artifactSha256: List.filled(64, 'a').join(),
  approvedCapabilities: const [],
  extensionPoints: const [],
  enabled: true,
  installedAt: 0,
);

void main() {
  test('only a hook asks again on a new version of the same build', () {
    final manifest = api.DockManifest.fromJson(dockManifestJson('m', '2.0.0'));
    final older = _installed('1.0.0');

    for (final hook in ['interceptors', 'permission.hook']) {
      expect(dockNeedsReapproval(hook, manifest, older), isTrue, reason: hook);
      expect(dockNeedsReapproval(hook, manifest, _installed('2.0.0')), isFalse);
    }
    expect(dockNeedsReapproval('message.post', manifest, older), isFalse);
    expect(dockNeedsReapproval('log.read', manifest, older), isFalse);
  });

  group('the record a step acts on', () {
    eachDockUpdateSize('is read when that step starts', (tester, size) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', asks: ['kv.store']),
        const DockUpdateMod(
          'b',
          asks: ['kv.store', 'log.read'],
          approvedBefore: ['kv.store'],
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text('Update Mod a?'), findsOneWidget);

      _revokeHostAccess(world, 'b');
      await tapDock(tester, _approve);
      expect(find.text('Update Mod b?'), findsOneWidget);
      await tapDock(tester, _approve);

      expect(world.installs, ['a', 'b']);
      expect(world.bodies.last['approved_host_capabilities'], ['log.read']);
    });

    eachDockUpdateSize('is read again once the admin agrees', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'b',
          asks: ['kv.store', 'log.read'],
          approvedBefore: ['kv.store'],
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text('Update Mod b?'), findsOneWidget);

      _revokeHostAccess(world, 'b');
      await tapDock(tester, _approve);

      expect(world.bodies.single['approved_host_capabilities'], ['log.read']);
    });

    eachDockUpdateSize('is not installed again when it was uninstalled', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', asks: ['kv.store']),
        const DockUpdateMod('b', asks: ['log.read']),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');

      world.installed.remove('b');
      await tapDock(tester, _approve);

      expect(world.installs, ['a']);
      expect(find.text('Update Mod b?'), findsNothing);
    });

    eachDockUpdateSize('is not installed when it was uninstalled mid-sheet', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod('a', asks: ['kv.store']),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text('Update Mod a?'), findsOneWidget);

      world.installed.remove('a');
      await tapDock(tester, _approve);

      expect(world.installs, isEmpty);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Updated 0 of 1'), findsNothing);
    });
  });

  group('the give-back', () {
    DockUpdateWorld withdrawnKvStore() => DockUpdateWorld([
      const DockUpdateMod(
        'a',
        asks: ['kv.store', 'log.read'],
        approvedBefore: ['kv.store', 'log.read'],
        dropsOnCarry: ['kv.store'],
      ),
    ]);
    const title = 'Mod a is updated. Give back its access?';

    eachDockUpdateSize('reads the record again once the admin agrees', (
      tester,
      size,
    ) async {
      final world = withdrawnKvStore();
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text(title), findsOneWidget);

      _revokeHostAccess(world, 'a');
      await tapDock(tester, 'Give access back');

      expect(world.installs, ['a', 'a']);
      expect(world.bodies.last['approved_host_capabilities'], ['kv.store']);
    });

    eachDockUpdateSize('is not installed when it was uninstalled mid-sheet', (
      tester,
      size,
    ) async {
      final world = withdrawnKvStore();
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(find.text(title), findsOneWidget);

      world.installed.remove('a');
      await tapDock(tester, 'Give access back');

      expect(world.installs, ['a']);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('without the access'), findsNothing);
    });
  });

  group('access this client cannot describe', () {
    eachDockUpdateSize('is never offered back, so nothing breaks', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['x.future'],
          approvedBefore: ['x.future'],
          dropsOnCarry: ['x.future'],
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Give back its access'), findsNothing);
      expect(world.installs, ['a']);
      expect(find.textContaining('without the access'), findsNothing);
    });

    eachDockUpdateSize('is left out of the give-back that shows the rest', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['kv.store', 'x.future'],
          approvedBefore: ['kv.store', 'x.future'],
          dropsOnCarry: ['kv.store', 'x.future'],
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);
      await tapDock(tester, 'Update all');
      expect(tester.takeException(), isNull);
      expect(find.text('Mod a is updated. Give back its access?'), findsOne);
      expect(find.text(dockCapabilityWarning('kv.store')!), findsOneWidget);

      await tapDock(tester, 'Give access back');

      expect(world.bodies.last['approved_host_capabilities'], ['kv.store']);
    });
  });

  group('a hook', () {
    for (final hook in ['interceptors', 'permission.hook']) {
      eachDockUpdateSize('on the same build is asked about up front ($hook)', (
        tester,
        size,
      ) async {
        final world = DockUpdateWorld([
          DockUpdateMod(
            'a',
            asks: [hook],
            approvedBefore: [hook],
            dropsOnCarry: [hook],
          ),
        ]);
        await openDockUpdateWorld(tester, world, size);

        await tapDock(tester, 'Update all');

        expect(find.text('Update Mod a?'), findsOneWidget);
        expect(find.text(dockCapabilityWarning(hook)!), findsOneWidget);
        await tapDock(tester, _approve);
        expect(world.installs, ['a']);
        expect(world.bodies.single['approved_host_capabilities'], [hook]);
        expect(find.textContaining('Give back its access'), findsNothing);
      });
    }

    eachDockUpdateSize('is shown when the step asks for something else', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        const DockUpdateMod(
          'a',
          asks: ['interceptors', 'kv.store'],
          approvedBefore: ['interceptors'],
          dropsOnCarry: ['interceptors'],
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text(dockCapabilityWarning('kv.store')!), findsOneWidget);
      expect(
        find.text(dockCapabilityWarning('interceptors')!),
        findsOneWidget,
        reason: 'a widened hook is not kept without a word',
      );
      await tapDock(tester, 'Skip');
      expect(world.installs, isEmpty);
    });
  });
}
