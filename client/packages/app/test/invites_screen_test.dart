// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the invites screen: creating one posts the chosen options, and
/// revoking one is gated behind a confirmation that actually says what
/// happens, matching `confirm_dialog.dart`'s contract.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/invites_screen.dart';
import 'package:slimm_app/src/widgets/toast_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_app/src/action_labels.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _inviteJson(
  String code, {
  bool revoked = false,
  int? maxUses,
  int uses = 0,
  int? expiresAt,
  bool usable = true,
  String? roleGrant,
}) => jsonEncode({
  'code': code,
  'max_uses': maxUses,
  'uses': uses,
  'expires_at': expiresAt,
  'created_at': 0,
  'revoked': revoked,
  'usable': usable,
  'role_grant': roleGrant,
});

Future<ProviderContainer> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) handler,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      // CREATE_INVITE only: MANAGE_SERVER would add a row this mock cannot serve.
      myPermissionsProvider.overrideWithValue(Perm.createInvite),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => handler(request)),
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
        home: const InvitesScreen(),
        builder: (context, child) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            const Positioned.fill(child: ToastOverlay()),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'revoking an invite is blocked until the confirmation is accepted',
    (tester) async {
      final deletes = <Uri>[];
      var listed = false;
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/invites') {
          listed = true;
          return http.Response(
            '[${_inviteJson('welcome-123')}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE') {
          deletes.add(request.url);
          return http.Response('', 204);
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'application/json'},
        );
      });
      expect(listed, isTrue);
      expect(find.text('welcome-123'), findsOneWidget);

      // Cancelling leaves the invite alone: no DELETE is ever sent.
      await tester.tap(find.byIcon(AppIcons.revoke));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletes, isEmpty);
      expect(find.text('welcome-123'), findsOneWidget);

      // Confirming sends exactly one DELETE for the code shown.
      await tester.tap(find.byIcon(AppIcons.revoke));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      expect(deletes, hasLength(1));
      expect(deletes.single.path, '/invites/welcome-123');
    },
  );

  testWidgets('creating an invite posts the chosen uses and shows the code', (
    tester,
  ) async {
    final posts = <(Uri, Map<String, dynamic>)>[];
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/invites') {
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && request.url.path == '/invites') {
        posts.add((
          request.url,
          jsonDecode(request.body) as Map<String, dynamic>,
        ));
        return http.Response(
          _inviteJson('fresh-code'),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.enterText(find.byType(TextField).first, '5');
    await tester.tap(find.text(ActionLabels.createInvite));
    await tester.pumpAndSettle();

    expect(posts, hasLength(1));
    expect(posts.single.$2, {'max_uses': 5});
    expect(find.text('fresh-code'), findsOneWidget);
  });

  testWidgets('an empty "Uses allowed" still creates an unlimited invite', (
    tester,
  ) async {
    final posts = <Map<String, dynamic>>[];
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/invites') {
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && request.url.path == '/invites') {
        posts.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          _inviteJson('fresh-code'),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    // Blank is the deliberate way to ask for unlimited; it must still work.
    await tester.tap(find.text(ActionLabels.createInvite));
    await tester.pumpAndSettle();

    expect(posts, hasLength(1));
    expect(posts.single, isEmpty, reason: 'no max_uses key means unlimited');
    expect(find.text('fresh-code'), findsOneWidget);
  });

  testWidgets(
    'a typo in "Uses allowed" is refused rather than becoming unlimited',
    (tester) async {
      var posted = false;
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/invites') {
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path == '/invites') {
          posted = true;
          return http.Response(
            _inviteJson('fresh-code'),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'application/json'},
        );
      });

      // Digits alone reach the field; an int too long to parse is what remains.
      await tester.enterText(find.byType(TextField).first, '9' * 25);
      await tester.pump();
      expect(
        find.text('Enter a number above 0, or leave blank for unlimited.'),
        findsOneWidget,
      );

      await tester.tap(find.text(ActionLabels.createInvite));
      await tester.pumpAndSettle();

      expect(posted, isFalse);
      expect(find.text('fresh-code'), findsNothing);
    },
  );

  testWidgets(
    'a create that fails outside ApiException still clears the busy flag',
    (tester) async {
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/invites') {
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path == '/invites') {
          // A body missing required fields makes fromJson throw a bare TypeError.
          return http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'application/json'},
        );
      });

      // This type deliberately escapes uncaught; a zone catches it here instead.
      Object? escaped;
      await runZonedGuarded(() async {
        await tester.tap(find.text(ActionLabels.createInvite));
        await tester.pump();
        await tester.pump();
      }, (error, stack) => escaped = error);

      expect(escaped, isA<TypeError>());
      expect(find.text('Creating...'), findsNothing);
      expect(find.text(ActionLabels.createInvite), findsOneWidget);

      final button = tester.widget<AppButton>(find.byType(AppButton));
      expect(button.disabled, isFalse);
    },
  );

  /// The create card used to render `e.message` in a `SnackBar`, so a
  /// dropped connection surfaced its own Dart exception string.
  testWidgets(
    'a create that cannot reach the server shows a safe sentence inline',
    (tester) async {
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/invites') {
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path == '/invites') {
          throw const SocketException('connection refused');
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'application/json'},
        );
      });

      await tester.tap(find.text(ActionLabels.createInvite));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(
        find.textContaining('the server could not be reached'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a fully used invite reads as such, not as expired', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/invites') {
        return http.Response(
          '[${_inviteJson('AB12CD34EF', maxUses: 10, uses: 10, usable: false)}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    expect(find.text('10/10 uses · Never expires'), findsOneWidget);
    expect(
      find.text('FULLY USED'),
      findsOneWidget,
      reason:
          'a spent code needs its own label; "10/10 uses" sitting under '
          '"EXPIRED" tells an admin the wrong thing is wrong',
    );
    expect(find.text('EXPIRED'), findsNothing);
  });

  testWidgets('a genuinely expired invite is labelled that way', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/invites') {
        return http.Response(
          '[${_inviteJson('GH56IJ78KL', expiresAt: 1, usable: false)}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    expect(find.text('EXPIRED'), findsOneWidget);
    expect(find.text('FULLY USED'), findsNothing);
  });

  testWidgets('the role an invite grants is named, not hidden', (tester) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/invites') {
        return http.Response(
          '[${_inviteJson('MN90OP12QR', roleGrant: 'role-1')}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && request.url.path == '/roles') {
        return http.Response(
          jsonEncode([
            {
              'id': 'role-1',
              'name': 'Moderators',
              'permissions': 0,
              'is_everyone': false,
              'created_at': 0,
            },
          ]),
          200,
        );
      }
      return http.Response(
        '{}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    expect(find.textContaining('Moderators'), findsOneWidget);
  });

  testWidgets('an existing code can be copied without revoking it', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/invites') {
        return http.Response(
          '[${_inviteJson('welcome-123')}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{}',
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.tap(find.byIcon(AppIcons.copy));
    await tester.pump();

    expect(find.text('Invite code copied.'), findsOneWidget);
    // Drains the toast's own dismiss timer so it is not still pending once this test tears down.
    await tester.pump(const Duration(seconds: 5));
  });
}
