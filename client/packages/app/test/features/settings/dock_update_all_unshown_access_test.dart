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

api.InstalledDockModule _installed(
  String version, {
  List<api.DockHookDecl> interceptors = const [],
  List<api.DockHookDecl> permissionHooks = const [],
}) => api.InstalledDockModule(
  id: 'm',
  name: 'm',
  version: version,
  artifactSha256: List.filled(64, 'a').join(),
  approvedCapabilities: const [],
  extensionPoints: const [],
  enabled: true,
  installedAt: 0,
  interceptors: interceptors,
  permissionHooks: permissionHooks,
);

api.DockHookDecl _interceptor(List<String> reads, {String phase = 'reject'}) =>
    api.DockHookDecl(hook: 'message.pre_send', phase: phase, reads: reads);

api.DockManifest _manifestWith({
  List<api.DockHookDecl> interceptors = const [],
  List<api.DockHookDecl> permissionHooks = const [],
}) => api.DockManifest.fromJson(
  dockManifestJson(
    'm',
    '1.0.0',
    extras: {
      'interceptors': [
        for (final h in interceptors)
          {'hook': h.hook, 'phase': h.phase, 'reads': h.reads},
      ],
      'permission_hooks': [
        for (final h in permissionHooks) {'hook': h.hook, 'reads': h.reads},
      ],
    },
  ),
);

/// The hook JSON a mod holds or is offered for [capability], reading [reads].
Map<String, List<Map<String, dynamic>>> _hookJson(
  String capability,
  List<String> reads,
) => switch (capability) {
  'interceptors' => {
    'interceptors': [
      {'hook': 'message.pre_send', 'phase': 'reject', 'reads': reads},
    ],
  },
  _ => {
    'permission_hooks': [
      {'hook': 'message.send', 'reads': reads},
    ],
  },
};

/// What the consent sentence for [capability] names when its hook reads [reads].
String _hookWarning(String capability, List<String> reads) =>
    dockCapabilityWarning(
      capability,
      details: capability == 'interceptors' ? reads : ['message.send'],
    )!;

void main() {
  group('a hook asks again', () {
    final held = _installed(
      '1.0.0',
      interceptors: [
        _interceptor(['channel_id']),
      ],
      permissionHooks: const [
        api.DockHookDecl(hook: 'message.send', reads: ['member_joined_ms']),
      ],
    );
    final same = _manifestWith(
      interceptors: [
        _interceptor(['channel_id']),
      ],
      permissionHooks: const [
        api.DockHookDecl(hook: 'message.send', reads: ['member_joined_ms']),
      ],
    );

    void expectBoth(api.DockManifest manifest, {required bool asks}) {
      for (final hook in ['interceptors', 'permission.hook']) {
        expect(dockNeedsReapproval(hook, manifest, held), asks, reason: hook);
      }
    }

    test('not when the same hooks stand, whatever the version', () {
      expectBoth(same, asks: false);
      final bumped = api.DockManifest.fromJson({
        ...dockManifestJson('m', '2.0.0'),
        'interceptors': [
          {
            'hook': 'message.pre_send',
            'phase': 'reject',
            'reads': ['channel_id'],
          },
        ],
        'permission_hooks': [
          {
            'hook': 'message.send',
            'reads': ['member_joined_ms'],
          },
        ],
      });
      expectBoth(bumped, asks: false);
    });

    test('when an interceptor reads more on the same version', () {
      expectBoth(
        _manifestWith(
          interceptors: [
            _interceptor(['channel_id', 'content']),
          ],
          permissionHooks: same.permissionHooks,
        ),
        asks: true,
      );
    });

    test('when a permission hook reads more', () {
      expectBoth(
        _manifestWith(
          interceptors: same.interceptors,
          permissionHooks: const [
            api.DockHookDecl(
              hook: 'message.send',
              reads: ['member_joined_ms', 'x.more'],
            ),
          ],
        ),
        asks: true,
      );
    });

    test('when a hook is new or stands in another phase', () {
      expectBoth(
        _manifestWith(
          interceptors: [
            ...same.interceptors,
            _interceptor(['channel_id'], phase: 'annotate'),
          ],
          permissionHooks: same.permissionHooks,
        ),
        asks: true,
      );
    });

    test('not when a hook reads less or is dropped', () {
      expectBoth(
        _manifestWith(interceptors: [_interceptor(const [])]),
        asks: false,
      );
    });

    test('when the record holds none, as from a server that sends none', () {
      expect(
        dockNeedsReapproval('interceptors', same, _installed('1.0.0')),
        isTrue,
      );
    });

    test('and so does a new build, whatever its hooks', () {
      final newBuild = api.DockManifest.fromJson({
        ...dockManifestJson('m', '1.0.0'),
        'artifact': {
          'kind': 'wasm',
          'path': 'x',
          'sha256': List.filled(64, 'c').join(),
        },
      });
      expectBoth(newBuild, asks: true);
    });

    test('while a host power that is not a hook does not', () {
      final manifest = api.DockManifest.fromJson(
        dockManifestJson('m', '2.0.0'),
      );
      final older = _installed('1.0.0');
      expect(dockNeedsReapproval('message.post', manifest, older), isFalse);
      expect(dockNeedsReapproval('log.read', manifest, older), isFalse);
    });
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
      eachDockUpdateSize('that reads more is asked about up front ($hook)', (
        tester,
        size,
      ) async {
        final world = DockUpdateWorld([
          DockUpdateMod(
            'a',
            asks: [hook],
            approvedBefore: [hook],
            dropsOnCarry: [hook],
            heldHooks: _hookJson(hook, ['channel_id']),
            offeredHooks: _hookJson(hook, ['channel_id', 'content']),
          ),
        ]);
        await openDockUpdateWorld(tester, world, size);

        await tapDock(tester, 'Update all');

        expect(find.text('Update Mod a?'), findsOneWidget);
        expect(
          find.text(_hookWarning(hook, ['channel_id', 'content'])),
          findsOneWidget,
        );
        await tapDock(tester, _approve);
        expect(world.installs, ['a']);
        expect(world.bodies.single['approved_host_capabilities'], [hook]);
        expect(find.textContaining('Give back its access'), findsNothing);
      });

      eachDockUpdateSize(
        'that stands as it did is carried without asking ($hook)',
        (tester, size) async {
          final world = DockUpdateWorld([
            DockUpdateMod(
              'a',
              asks: [hook],
              approvedBefore: [hook],
              heldHooks: _hookJson(hook, ['channel_id']),
              offeredHooks: _hookJson(hook, ['channel_id']),
            ),
          ]);
          await openDockUpdateWorld(tester, world, size);

          await tapDock(tester, 'Update all');

          expect(find.text('Update Mod a?'), findsNothing);
          expect(world.installs, ['a']);
          expect(world.bodies.single['approved_host_capabilities'], isNull);
          expect(world.installed['a']!['approved_host_capabilities'], [hook]);
          expect(find.textContaining('Give back its access'), findsNothing);
        },
      );
    }

    eachDockUpdateSize('is shown when the step asks for something else', (
      tester,
      size,
    ) async {
      final world = DockUpdateWorld([
        DockUpdateMod(
          'a',
          asks: ['interceptors', 'kv.store'],
          approvedBefore: ['interceptors'],
          dropsOnCarry: ['interceptors'],
          heldHooks: _hookJson('interceptors', ['channel_id']),
          offeredHooks: _hookJson('interceptors', ['channel_id', 'content']),
        ),
      ]);
      await openDockUpdateWorld(tester, world, size);

      await tapDock(tester, 'Update all');

      expect(find.text(dockCapabilityWarning('kv.store')!), findsOneWidget);
      expect(
        find.text(_hookWarning('interceptors', ['channel_id', 'content'])),
        findsOneWidget,
        reason: 'a widened hook is not kept without a word',
      );
      await tapDock(tester, 'Skip');
      expect(world.installs, isEmpty);
    });
  });
}
