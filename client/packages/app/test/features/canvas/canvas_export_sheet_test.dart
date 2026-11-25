// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Export canvas" sheet: its form, the one id every attempt sends, each outcome's words and buttons, and the toast that opens the copy.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_export_sheet.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../ui_snapshot_support.dart' show teardownFixture;

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);
const _json = {'content-type': 'application/json'};

typedef _Answer = FutureOr<http.Response> Function(Map<String, dynamic> body);

http.Response _exported({int spared = 0, String name = 'minecraft canvas'}) =>
    http.Response(
      jsonEncode({
        'channel': {
          'id': 'new-channel',
          'name': name,
          'kind': 'canvas',
          'created_at': 1,
        },
        'copied': 3,
        'skipped': 0,
        'cleared': 0,
        'spared': spared,
      }),
      200,
      headers: _json,
    );

http.Response _refused(int status, String error, {String? code}) =>
    http.Response(
      jsonEncode({'error': error, 'code': ?code}),
      status,
      headers: _json,
    );

class _Rig {
  _Rig(this.tester, this.container, this.router, this.bodies);

  final WidgetTester tester;
  final ProviderContainer container;
  final GoRouter router;
  final List<Map<String, dynamic>> bodies;

  List<ToastMessage> get toasts => container.read(toastsProvider);

  Future<void> open() async {
    await tester.tap(find.text('open'));
    await pumpFrames(tester, frames: 30);
  }

  Future<void> submit(String label) async {
    final before = bodies.length;
    await tester.tap(find.text(label));
    await waitUntil(tester, () => bodies.length > before);
    await pumpFrames(tester, frames: 30);
  }
}

Future<_Rig> _rig(
  WidgetTester tester, {
  required _Answer answer,
  int permissions = Perm.manageChannels,
  int channelPermissions = Perm.manageCanvas,
  Map<String, dynamic> source = const {},
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await tester.runAsync(() async {
    await store.upsertChannels([
      api.Channel.fromJson({
        'id': 'board',
        'name': 'minecraft',
        'kind': 'voice',
        'created_at': 0,
        'canvas_enabled': true,
        ...source,
      }),
    ]);
    await store.replaceCategories([
      api.ChannelCategory.fromJson({
        'id': 'gamers',
        'name': 'Gamers',
        'position': 0,
        'created_at': 0,
      }),
    ]);
  });
  final bodies = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      myPermissionsProvider.overrideWithValue(permissions),
      myChannelPermissionsProvider(
        'board',
      ).overrideWithValue(channelPermissions),
      mockApiOverride((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        return answer(body);
      }),
    ],
  );
  _finishers.add(() => teardownFixture(tester, container, db));
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(
        path: '/start',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => showCanvasExportSheet(context, 'board'),
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (_, __) => const Placeholder(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return _Rig(tester, container, router, bodies);
}

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is AppButton && w.label == label);

AppButton _buttonWidget(WidgetTester tester, String label) =>
    tester.widget<AppButton>(_button(label));

String _name(WidgetTester tester) => tester
    .widget<AppInput>(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.placeholder == 'Channel name',
      ),
    )
    .controller!
    .text;

final _finishers = <Future<void> Function()>[];

/// A test whose store streams are let go inside it, before the framework checks for stray timers.
void _test(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final finish in _finishers) {
        await finish();
      }
      _finishers.clear();
    }
  });
}

void main() {
  _test(
    'the name starts as "<source> canvas" and the sheet says what it does',
    (tester) async {
      final rig = await _rig(tester, answer: (_) => _exported());
      await rig.open();

      expect(find.text('Export canvas'), findsOneWidget);
      expect(find.text('Export to canvas channel'), findsOneWidget);
      expect(
        find.text('Copies this board into a new canvas channel.'),
        findsOneWidget,
      );
      expect(_name(tester), 'minecraft canvas');
      expect(find.text('Voice call'), findsOneWidget);
    },
  );

  _test(
    'a very long source name is cut so the default still fits the name limit',
    (tester) async {
      final long = 'x' * 64;
      expect(exportDefaultName(long).length, lessThanOrEqualTo(64));
      expect(exportDefaultName(long).endsWith(' canvas'), isTrue);
      expect(exportDefaultName('minecraft'), 'minecraft canvas');
    },
  );

  _test('"Clear this canvas after" is only offered with MANAGE_CANVAS', (
    tester,
  ) async {
    final without = await _rig(
      tester,
      answer: (_) => _exported(),
      channelPermissions: 0,
    );
    await without.open();
    expect(find.text('Clear this canvas after'), findsNothing);
    expect(find.text('Export'), findsOneWidget);
  });

  _test('turning the clear on makes the button danger-toned and renames it', (
    tester,
  ) async {
    final rig = await _rig(tester, answer: (_) => _exported());
    await rig.open();
    expect(_buttonWidget(tester, 'Export').variant, AppButtonVariant.primary);
    expect(
      find.text('Removes everything here once the copy is made.'),
      findsOneWidget,
    );

    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is AppToggle &&
            w.semanticLabel == 'Clear this canvas after exporting',
      ),
    );
    await pumpFrames(tester, frames: 30);

    expect(
      _buttonWidget(tester, 'Export and clear').variant,
      AppButtonVariant.danger,
    );
  });

  _test("the copy is filed under the source's own category by default", (
    tester,
  ) async {
    final rig = await _rig(
      tester,
      answer: (_) => _exported(),
      source: {'category_id': 'gamers'},
    );
    await rig.open();
    expect(find.text('Gamers'), findsOneWidget);
    await rig.submit('Export');

    expect(rig.bodies.single['category_id'], 'gamers');
  });

  _test('a restricted source says who will see the copy', (tester) async {
    final rig = await _rig(
      tester,
      answer: (_) => _exported(),
      source: {'restricted': true},
    );
    await rig.open();
    expect(
      find.text('Visible to the same people as this channel.'),
      findsOneWidget,
    );
  });

  _test(
    'without permission to manage channels the sheet explains and offers no export',
    (tester) async {
      final rig = await _rig(
        tester,
        answer: (_) => _exported(),
        permissions: 0,
      );
      await rig.open();

      expect(
        find.text('You need permission to manage channels to export.'),
        findsOneWidget,
      );
      expect(_button('Export'), findsNothing);
      expect(_button('Cancel'), findsOneWidget);
    },
  );

  _test('Cancel and Export sit side by side, equal and inside the sheet', (
    tester,
  ) async {
    final rig = await _rig(
      tester,
      answer: (_) => _exported(),
      size: const Size(390, 844),
    );
    await rig.open();

    final cancel = tester.getRect(_button('Cancel'));
    final export = tester.getRect(_button('Export'));
    expect((cancel.top - export.top).abs(), lessThan(1));
    expect((cancel.width - export.width).abs(), lessThan(1));
    expect(cancel.right, lessThan(export.left));
    expect(export.right, lessThanOrEqualTo(390 - AppSpacing.s16 + 1));
    expect(cancel.left, greaterThanOrEqualTo(AppSpacing.s16 - 1));
  });

  _test(
    'every attempt from one sheet sends the same id, and a reopened sheet a new one',
    (tester) async {
      final rig = await _rig(
        tester,
        answer: (_) => _refused(500, 'internal error'),
      );
      await rig.open();
      await rig.submit('Export');
      await rig.submit('Try again');
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester, frames: 30);
      await rig.open();
      await rig.submit('Export');

      expect(rig.bodies, hasLength(3));
      expect(rig.bodies[1]['id'], rig.bodies[0]['id']);
      expect(rig.bodies[2]['id'], isNot(rig.bodies[0]['id']));
      expect(rig.bodies[0]['name'], 'minecraft canvas');
      expect(rig.bodies[0]['clear_source'], false);
      expect(rig.bodies[0]['voice_enabled'], false);
      expect(rig.bodies[0].containsKey('category_id'), isTrue);
    },
  );

  _test('an error answer says nothing was changed and offers Try again', (
    tester,
  ) async {
    final rig = await _rig(
      tester,
      answer: (_) => _refused(409, 'this canvas is full'),
    );
    await rig.open();
    await rig.submit('Export');

    expect(
      find.text('This canvas is full. Nothing was changed.'),
      findsOneWidget,
    );
    expect(_button('Try again'), findsOneWidget);
  });

  _test(
    'no answer says it will not make a second copy and keeps the form still',
    (tester) async {
      final rig = await _rig(
        tester,
        answer: (_) => throw http.ClientException('connection refused'),
      );
      await rig.open();
      await rig.submit('Export');

      expect(
        find.text(
          "Couldn't reach the server. Try again; it won't make a second copy.",
        ),
        findsOneWidget,
      );
      expect(_button('Try again'), findsOneWidget);
      final input = tester.widget<AppInput>(
        find.byWidgetPredicate(
          (w) => w is AppInput && w.placeholder == 'Channel name',
        ),
      );
      expect(
        input.enabled,
        isFalse,
        reason: 'the retry must be the same request',
      );
    },
  );

  _test('a board too big to export offers Cancel and nothing to try', (
    tester,
  ) async {
    final rig = await _rig(
      tester,
      answer: (_) => _refused(
        409,
        'This canvas is too big to export.',
        code: api.CanvasExportRefusal.tooLarge,
      ),
    );
    await rig.open();
    await rig.submit('Export');

    expect(find.text('This canvas is too big to export.'), findsOneWidget);
    expect(_button('Cancel'), findsOneWidget);
    expect(_button('Try again'), findsNothing);
    expect(_button('Export'), findsNothing);
  });

  _test('a board already being exported says so and offers Try again', (
    tester,
  ) async {
    final rig = await _rig(
      tester,
      answer: (_) => _refused(
        409,
        'This canvas is being exported already.',
        code: api.CanvasExportRefusal.busy,
      ),
    );
    await rig.open();
    await rig.submit('Export');

    expect(find.text('This canvas is being exported already.'), findsOneWidget);
    expect(_button('Try again'), findsOneWidget);
  });

  _test(
    'success closes the sheet and toasts with Open, which goes to the copy',
    (tester) async {
      final rig = await _rig(tester, answer: (_) => _exported(spared: 2));
      await rig.open();
      await rig.submit('Export');

      expect(find.text('Export canvas'), findsNothing);
      final toast = rig.toasts.single;
      expect(
        toast.message,
        'Exported to minecraft canvas. 2 locked items stayed.',
      );
      expect(toast.actionLabel, 'Open');
      toast.onAction!();
      await pumpFrames(tester, frames: 10);
      expect(
        rig.router.routerDelegate.currentConfiguration.uri.path,
        Routes.channel('new-channel'),
      );
    },
  );

  _test('success after a retry toasts the same way', (tester) async {
    var calls = 0;
    final rig = await _rig(
      tester,
      answer: (_) =>
          ++calls == 1 ? throw http.ClientException('lost') : _exported(),
    );
    await rig.open();
    await rig.submit('Export');
    await rig.submit('Try again');

    expect(rig.toasts.single.message, 'Exported to minecraft canvas.');
    expect(rig.toasts.single.actionLabel, 'Open');
    expect(rig.bodies[1]['id'], rig.bodies[0]['id']);
  });
}
