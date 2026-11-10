// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Checks card on a module's Dock page: this module's hooks only, hidden
/// when it has none, one press to reorder or to refuse on failure, and a
/// failure stays on the card.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_hooks_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _hook(String module, {int priority = 100}) => {
  'module_id': module,
  'module_name': module,
  'kind': 'interceptor',
  'hook': 'message.pre_send',
  'phase': 'reject',
  'reads': ['content'],
  'priority': priority,
  'fail_closed': false,
  'live': true,
  'runs': 4,
  'failures': 1,
  'last_error': 'trapped',
  'max_fuel_used': 3,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> _pump(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler,
) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(handler),
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: DockHooksCard(moduleId: 'filter')),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// Lets the mocked round trip resolve, then the rebuild after it.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('it lists this module\'s hooks and how they have been doing', (
    tester,
  ) async {
    await _pump(tester, (_) async => _json([_hook('filter'), _hook('other')]));
    expect(find.text('Before a message is sent: can block it'), findsOneWidget);
    expect(
      find.textContaining('4 runs, 1 failed. Last problem: trapped'),
      findsOneWidget,
    );
  });

  testWidgets('a module with no hooks shows nothing', (tester) async {
    await _pump(tester, (_) async => _json([_hook('other')]));
    expect(find.text('Checks'), findsNothing);
  });

  testWidgets('Run later sends a higher priority and Refuse sends the switch', (
    tester,
  ) async {
    final puts = <Map<String, dynamic>>[];
    await _pump(tester, (request) async {
      if (request.method == 'PUT') {
        puts.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }
      return _json([_hook('filter')]);
    });
    await tester.tap(find.byTooltip('Run later'));
    await _settle(tester);
    expect(puts.single['priority'], 110);
    expect(puts.single['hook'], 'message.pre_send');
    expect(puts.single['phase'], 'reject');
    expect(puts.single.containsKey('fail_closed'), isFalse);
    await tester.tap(find.byWidgetPredicate((w) => w is AppToggle));
    await _settle(tester);
    expect(puts.last['fail_closed'], isTrue);
  });

  testWidgets('a failed change is an error state, not a snackbar', (
    tester,
  ) async {
    await _pump(tester, (request) async {
      if (request.method == 'PUT') return _json({'error': 'no'}, 500);
      return _json([_hook('filter')]);
    });
    await tester.tap(find.byTooltip('Run earlier'));
    await _settle(tester);
    expect(find.byWidgetPredicate((w) => w is AppErrorState), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SnackBar), findsNothing);
    expect(find.text('Could not change the check.'), findsOneWidget);
  });

  testWidgets('a failed change offers Dismiss, which clears it without a '
      'second request', (tester) async {
    var puts = 0;
    await _pump(tester, (request) async {
      if (request.method == 'PUT') {
        puts++;
        return _json({'error': 'no'}, 500);
      }
      return _json([_hook('filter')]);
    });
    await tester.tap(find.byTooltip('Run earlier'));
    await _settle(tester);
    expect(find.text('Retry'), findsNothing);

    await tester.tap(find.text('Dismiss'));
    await _settle(tester);

    expect(find.text('Could not change the check.'), findsNothing);
    expect(puts, 1);
  });

  testWidgets('a checks list that will not load says which part failed', (
    tester,
  ) async {
    await _pump(tester, (_) async => _json({'error': 'down'}, 500));
    expect(find.text('Could not load the checks.'), findsOneWidget);
  });
}
