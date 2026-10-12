// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin controls for the invite landing card: saving the description,
/// uploading and removing the banner, and the failure shape.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/attachment_picker.dart';
import 'package:slimm_app/src/widgets/invite_landing_card.dart';
import 'package:slimm_app/src/widgets/invite_landing_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'composer_harness.dart' show FakePlatformFile;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _json = {'content-type': 'application/json'};

class _Server {
  String description = '';
  int? banner;
  final calls = <String>[];
  Object? lastPatch;
  int uploadStatus = 200;

  http.Response handle(http.Request r) {
    calls.add('${r.method} ${r.url.path}');
    switch ((r.method, r.url.path)) {
      case ('GET', '/space/settings'):
        return http.Response(_settings(), 200, headers: _json);
      case ('PATCH', '/space/settings'):
        lastPatch = jsonDecode(r.body);
        description = (lastPatch as Map)['description'] as String;
        return http.Response(_settings(), 200, headers: _json);
      case ('POST', '/space/banner'):
        if (uploadStatus != 200) {
          return http.Response(
            jsonEncode({'error': 'unsupported banner type'}),
            uploadStatus,
            headers: _json,
          );
        }
        banner = 7;
        return http.Response(
          jsonEncode({'banner_updated_at': 7}),
          200,
          headers: _json,
        );
      case ('DELETE', '/space/banner'):
        banner = null;
        return http.Response('', 204);
      case ('GET', '/version'):
        return http.Response(
          jsonEncode({'name': 'Home', 'version': '1', 'protocol': 1}),
          200,
          headers: _json,
        );
      case ('GET', '/members'):
        return http.Response('[]', 200, headers: _json);
      default:
        return http.Response('{}', 404, headers: _json);
    }
  }

  String _settings() => jsonEncode({
    'join_policy': 'invite',
    'totp_policy': 'optional',
    'description': description,
    'banner_updated_at': banner,
  });
}

Future<void> _pump(WidgetTester tester, _Server server, double width) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final file = FakePlatformFile('b.png', Uint8List.fromList([1, 2, 3]));
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      attachmentPickerProvider.overrideWith(
        (ref, source) =>
            () async => file,
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => server.handle(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: InviteLandingSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'saving a description sends only it and previews it at $width',
      (tester) async {
        final server = _Server();
        await _pump(tester, server, width);
        expect(find.byType(InviteLandingCard), findsOneWidget);
        final save = find.widgetWithText(AppButton, 'Save description');
        expect(tester.widget<AppButton>(save).disabled, isTrue);

        await tester.enterText(
          find.byType(TextField),
          '  A small home server. ',
        );
        await tester.pump();
        expect(find.text('A small home server.'), findsWidgets);
        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(server.lastPatch, {'description': 'A small home server.'});
        expect(tester.widget<AppButton>(save).disabled, isTrue);
        final card = tester.getRect(find.byType(InviteLandingCard));
        expect(card.right, lessThanOrEqualTo(width));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('choosing a banner uploads it and offers to remove it', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, 390);
    expect(find.text('Remove banner'), findsNothing);
    await tester.tap(find.text('Choose banner'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('POST /space/banner'));
    expect(find.text('Replace banner'), findsOneWidget);

    await tester.tap(find.text('Remove banner'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('DELETE /space/banner'));
    expect(find.text('Choose banner'), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('a refused banner shows a persistent error, not a toast', (
    tester,
  ) async {
    final server = _Server()..uploadStatus = 400;
    await _pump(tester, server, 390);
    await tester.tap(find.text('Choose banner'));
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.text('Choose banner'), findsOneWidget);
  });
}
