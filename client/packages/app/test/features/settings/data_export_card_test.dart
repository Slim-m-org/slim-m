// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The data export cards: a member's own data in Account & devices, and the
/// whole Space for an administrator. Idle, building, ready, saving, failed and
/// expired, and the proof sheet that says exactly what an archive holds.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/download_target.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/features/settings/providers/data_exports.dart';
import 'package:slimm_app/src/features/settings/screens/admin/export_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/data_export_card.dart';
import 'package:slimm_app/src/features/settings/widgets/data_export_copy.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'u1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

Map<String, Object?> _job(
  String status, {
  String kind = 'member',
  int processed = 0,
  int total = 0,
  int? size,
  String? error,
  int? expiresAt,
}) => {
  'id': 'e1',
  'kind': kind,
  'status': status,
  'processed': processed,
  'total': total,
  'size_bytes': size,
  'error': error,
  'created_at': 1767225600000,
  'finished_at': null,
  'expires_at': expiresAt,
};

class _Target implements DownloadTarget {
  final bytes = <int>[];
  bool finished = false;

  @override
  int? get maxBytes => null;

  @override
  Future<void> write(List<int> chunk) async => bytes.addAll(chunk);

  @override
  Future<bool> finish() async => finished = true;

  @override
  Future<void> discard() async {}
}

class _Server {
  List<Map<String, Object?>> jobs = [];
  final calls = <String>[];
  Object? lastBody;
  bool refusePassword = false;

  Future<http.Response> handle(http.Request request) async {
    calls.add('${request.method} ${request.url.path}');
    final json = {'content-type': 'application/json'};
    final path = request.url.path;
    if (request.method == 'POST' && refusePassword) {
      return http.Response(
        jsonEncode({'error': 'that password is not correct'}),
        403,
        headers: json,
      );
    }
    if (request.method == 'POST') {
      lastBody = jsonDecode(request.body);
      final started = _job(
        'queued',
        kind: path.endsWith('space') ? 'space' : 'member',
      );
      jobs = [started];
      return http.Response(jsonEncode(started), 202, headers: json);
    }
    if (request.method == 'DELETE') {
      jobs = [];
      return http.Response('', 204);
    }
    if (path.endsWith('/download')) {
      return http.Response.bytes(
        [1, 2, 3, 4],
        200,
        headers: {'content-type': 'application/x-tar'},
      );
    }
    return http.Response(jsonEncode(jobs), 200, headers: json);
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Server server, {
  Widget child = const DataExportCard(copy: DataExportCopy.member),
  int permissions = 0,
  _Target? target,
  Duration poll = const Duration(hours: 1),
}) async {
  final client = MockClient(server.handle);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      myPermissionsProvider.overrideWithValue(permissions),
      exportPollIntervalProvider.overrideWithValue(poll),
      if (target != null)
        downloadTargetOpenerProvider.overrideWithValue((name) async => target),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

/// A building export shows a bar that animates and polls on a timer, so
/// pumpAndSettle would never return; a few short pumps let the requests land.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Drops the tree and the container so a poll timer is not left pending.
Future<void> _stop(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

AppButton _button(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label));

void main() {
  testWidgets(
    'idle: one action, and starting asks for the password and says what is in it',
    (tester) async {
      final server = _Server();
      final container = await _pump(tester, server);

      expect(find.text('Download my data'), findsOneWidget);
      await tester.tap(find.text('Prepare download...'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining("Never anyone else's messages"),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'hunter2hunter2');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, 'Prepare download'));
      await _settle(tester);

      expect(server.calls, contains('POST /exports/member'));
      expect(server.lastBody, {'password': 'hunter2hunter2'});
      await _stop(tester, container);
    },
  );

  testWidgets('building: a progress bar, a percentage, and no second start', (
    tester,
  ) async {
    final server = _Server()
      ..jobs = [_job('running', processed: 40, total: 100)];
    final container = await _pump(tester, server);

    expect(find.text('Preparing the archive'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.4,
    );
    expect(_button(tester, 'Prepare download...').onPressed, isNull);
    await _stop(tester, container);
  });

  testWidgets('a running export refreshes itself until it is ready', (
    tester,
  ) async {
    final server = _Server()..jobs = [_job('running', processed: 1, total: 4)];
    await _pump(tester, server, poll: const Duration(milliseconds: 50));
    expect(find.text('Preparing the archive'), findsOneWidget);

    server.jobs = [
      _job(
        'ready',
        size: 2048,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000 * 5,
      ),
    ];
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();

    expect(find.text('Ready to download'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
  });

  testWidgets('ready: Download streams the archive into the chosen file', (
    tester,
  ) async {
    final target = _Target();
    final server = _Server()
      ..jobs = [
        _job(
          'ready',
          size: 4,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 7200000,
        ),
      ];
    await _pump(tester, server, target: target);

    await tester.tap(find.widgetWithText(AppButton, 'Download'));
    await tester.pumpAndSettle();

    expect(server.calls, contains('GET /exports/e1/download'));
    expect(target.bytes, [1, 2, 3, 4]);
    expect(target.finished, isTrue);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets(
    'failed: the reason stays on screen until dismissed, and dismissing deletes it',
    (tester) async {
      final server = _Server()
        ..jobs = [_job('failed', error: 'the export could not be finished')];
      await _pump(tester, server);

      expect(find.text('the export could not be finished'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(server.calls, contains('DELETE /exports/e1'));
      expect(find.text('the export could not be finished'), findsNothing);
    },
  );

  testWidgets('expired: says so and offers to remove it', (tester) async {
    final server = _Server()..jobs = [_job('expired')];
    await _pump(tester, server);

    expect(find.text('The last export expired'), findsOneWidget);
    expect(_button(tester, 'Prepare download...').onPressed, isNotNull);
  });

  testWidgets('a refused password keeps the sheet open on the reason', (
    tester,
  ) async {
    final server = _Server()..refusePassword = true;
    await _pump(tester, server);

    await tester.tap(find.text('Prepare download...'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'wrong-password');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Prepare download'));
    await tester.pumpAndSettle();

    expect(find.text('That password is not correct.'), findsOneWidget);
  });

  testWidgets('the Space export is hidden from anyone but an administrator', (
    tester,
  ) async {
    await _pump(
      tester,
      _Server(),
      child: const ExportPane(),
      permissions: Perm.manageServer,
    );

    expect(find.text('Prepare export...'), findsNothing);
    expect(
      find.textContaining('needs the administrator permission'),
      findsOneWidget,
    );
  });

  testWidgets('an administrator sees the Space export and what it leaves out', (
    tester,
  ) async {
    await _pump(
      tester,
      _Server(),
      child: const ExportPane(),
      permissions: Perm.administrator,
    );

    await tester.tap(find.text('Prepare export...'));
    await tester.pumpAndSettle();

    expect(find.textContaining('never holds direct messages'), findsOneWidget);
  });
}
