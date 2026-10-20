// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `report_card.dart` renders a reported message snapshot through the same
/// [MessageBody] pipeline the channel transcript uses, but it built its own
/// `knownUsernames` set with `membersProvider.maybeWhen(data: ..., orElse: ()
/// => const {})` instead of reusing [knownUsernamesFrom]
/// (`channel_screen.dart`) - `orElse` fires on `AsyncError` exactly the same
/// as on `AsyncLoading`, so a `/members` refetch failing while a moderator
/// already has the queue open dropped every known username and unhighlighted
/// every mention in the reported snapshot. This is the same backlog #110
/// ("mentions also get unhighlighted when the server was offline") the
/// channel transcript itself was fixed for, just missed in this second
/// surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/reports_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'mod-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _report =
    '{"id":"report-1","reporter_id":null,"subject_kind":"message",'
    '"subject_id":"message-1","channel_id":"channel-1",'
    '"reason":"flagged","snapshot":"@ada can you take a look","created_at":0,'
    '"subject_author_id":null,"channel_permissions":null}';

/// A [ReportsScreen] whose `/members` answer can be flipped from a
/// one-member roster to a real dropped connection, the same shape
/// `connection_drop_ui_test.dart`'s own `_setup` drives.
({ProviderContainer container, void Function() disconnect}) _setup() {
  var connected = true;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.method == 'GET' && request.url.path == '/reports') {
          return http.Response(
            '[$_report]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path == '/members') {
          if (!connected) {
            throw http.ClientException('connection refused');
          }
          return http.Response(
            '[{"id":"ada","username":"ada","display_name":"Ada",'
            '"created_at":0}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path == '/me') {
          return http.Response(
            '{"id":"mod-1","username":"mod","display_name":"Mod",'
            '"created_at":0,"permissions":0}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ],
  );
  return (
    container: container,
    disconnect: () {
      connected = false;
      container.invalidate(membersProvider);
    },
  );
}

void main() {
  testWidgets(
    'a dropped /members refetch keeps an already-known mention highlighted '
    'in the report queue',
    (tester) async {
      final setup = _setup();
      addTearDown(setup.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: setup.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const ReportsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('@ada'),
        findsOneWidget,
        reason:
            'rendered as its own Text widget only inside the chip, never '
            'inside the plain-text fallback span',
      );

      setup.disconnect();
      await tester.pumpAndSettle();

      expect(
        find.text('@ada'),
        findsOneWidget,
        reason:
            'a failed /members refetch is not evidence the deployment has '
            'no members - unhighlighting this mention here is the same '
            'backlog #110 the channel transcript was already fixed for',
      );
    },
  );
}
