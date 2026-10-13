// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renaming the Space from the landing page section: what goes over the wire,
/// what the preview and the channel list header show after, and the failure.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/invite_landing_card.dart';
import 'package:slimm_app/src/widgets/invite_landing_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _json = {'content-type': 'application/json'};

class _Server {
  String name = 'slim-m';
  int patchStatus = 200;
  final patches = <Object?>[];
  int versionReads = 0;

  http.Response handle(http.Request r) {
    switch ((r.method, r.url.path)) {
      case ('GET', '/space/settings'):
        return http.Response(_settings(), 200, headers: _json);
      case ('PATCH', '/space/settings'):
        patches.add(jsonDecode(r.body));
        if (patchStatus != 200) {
          return http.Response(
            jsonEncode({'error': 'name must not be empty'}),
            patchStatus,
            headers: _json,
          );
        }
        name = (patches.last as Map)['name'] as String;
        return http.Response(_settings(), 200, headers: _json);
      case ('GET', '/version'):
        versionReads++;
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'space_name': name,
            'version': '1',
            'protocol': 1,
          }),
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
    'name': name,
    'join_policy': 'invite',
    'totp_policy': 'optional',
    'description': '',
    'banner_updated_at': null,
    'icon_updated_at': null,
  });
}

Future<void> _pump(WidgetTester tester, _Server server, double width) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
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
        home: Scaffold(
          body: Column(
            children: [
              // The header watches the same /version the rename refreshes.
              const RailHeader(),
              const Expanded(
                child: SingleChildScrollView(child: InviteLandingSection()),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _rename => find.widgetWithText(AppButton, 'Rename');

Finder get _field => find.descendant(
  of: find.bySemanticsLabel('Space name'),
  matching: find.byType(EditableText),
);

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('renaming sends only the name and updates the header at '
        '$width', (tester) async {
      final server = _Server();
      await _pump(tester, server, width);
      expect(tester.widget<AppButton>(_rename).disabled, isTrue);
      expect(
        find.descendant(
          of: find.byType(RailHeader),
          matching: find.text('slim-m'),
        ),
        findsOneWidget,
      );

      await tester.enterText(_field, "  Nick's place  ");
      await tester.pump();
      expect(tester.widget<AppButton>(_rename).disabled, isFalse);
      await tester.tap(_rename);
      await tester.pumpAndSettle();

      expect(server.patches, [
        {'name': "Nick's place"},
      ]);
      expect(
        find.descendant(
          of: find.byType(RailHeader),
          matching: find.text("Nick's place"),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<InviteLandingCard>(find.byType(InviteLandingCard)).name,
        "Nick's place",
      );
      expect(tester.widget<AppButton>(_rename).disabled, isTrue);
    });
  }

  testWidgets('a blank name cannot be sent', (tester) async {
    final server = _Server();
    await _pump(tester, server, 1280);
    await tester.enterText(_field, '   ');
    await tester.pump();
    expect(tester.widget<AppButton>(_rename).disabled, isTrue);
    expect(server.patches, isEmpty);
  });

  testWidgets('a refused rename shows a persistent error, not a snackbar', (
    tester,
  ) async {
    final server = _Server()..patchStatus = 400;
    await _pump(tester, server, 1280);
    await tester.enterText(_field, 'Elsewhere');
    await tester.pump();
    await tester.tap(_rename);
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.descendant(
        of: find.byType(RailHeader),
        matching: find.text('slim-m'),
      ),
      findsOneWidget,
    );
  });
}
