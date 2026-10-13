// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pasting an invite link into the redeem dialog.
///
/// The point of the link is that somebody handed one string does not have to
/// pull it apart. The point of this file is the other half: a link only fills
/// the fields in, and every check a typed address clears still runs on it.
/// A pasted server is exactly as untrusted as a typed one, and userinfo
/// smuggled through a link must be stripped by the same reduction that
/// `onboarding_screen_userinfo_test.dart` pins for typing.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/invite_link.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

MockClient _server() => MockClient((request) async {
  if (request.method == 'GET' && request.url.path == '/version') {
    return http.Response(
      jsonEncode(const {'name': 'slim-m', 'version': '0.6.0', 'protocol': 1}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.url.path.startsWith('/invites/')) {
    return http.Response(
      jsonEncode(const {
        'usable': true,
        'community': {'name': 'slim-m', 'member_count': 3},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  return http.Response('{}', 404);
});

Future<({Uri? chosen, Uri? probed, String? invite})> _pasteIntoDialog(
  WidgetTester tester,
  String pasted,
) async {
  Uri? chosen;
  Uri? probed;
  String? invite;
  final httpClient = _server();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      probeApiProvider.overrideWithValue((baseUrl) {
        probed = baseUrl;
        return SlimmApi(baseUrl: baseUrl, httpClient: httpClient);
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: OnboardingScreen(
          onServerChosen: (server, code) {
            chosen = server;
            invite = code;
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('I have an invite'));
  await tester.pumpAndSettle();
  // Into the code field, where somebody handed a link would most likely put it.
  await tester.enterText(find.byType(TextField).at(1), pasted);
  await tester.pumpAndSettle();
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  if (find.text('Join').evaluate().isNotEmpty) {
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
  }

  return (chosen: chosen, probed: probed, invite: invite);
}

/// The tapped-link half: a pending [tappedInviteProvider] opens the redeem
/// dialog with both fields prefilled, exactly as a paste would have, and
/// consumes itself so a rebuild does not reopen the dialog.
Future<void> _pumpWithTappedInvite(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      tappedInviteProvider.overrideWith(
        (ref) => (server: Uri.parse('https://chat.example:8443'), code: 'C1'),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: OnboardingScreen(onServerChosen: (server, code) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a pasted link fills in both the server and the code', (
    tester,
  ) async {
    final link = buildInviteLink(
      server: Uri.parse('https://chat.example'),
      code: 'CODE123',
    );

    final result = await _pasteIntoDialog(tester, link);

    expect(result.probed, Uri.parse('https://chat.example'));
    expect(result.chosen, Uri.parse('https://chat.example'));
    expect(result.invite, 'CODE123');
  });

  testWidgets('userinfo smuggled through a link is stripped before it is '
      'probed or kept, exactly as a typed one is', (tester) async {
    // The reduction stops dart:io turning userinfo into a Basic auth header on every later request.
    final link = buildInviteLink(
      server: Uri.parse('https://user:pass@chat.example/ignored?also=ignored'),
      code: 'CODE123',
    );

    final result = await _pasteIntoDialog(tester, link);

    expect(result.probed, Uri.parse('https://chat.example'));
    expect(result.chosen, Uri.parse('https://chat.example'));
  });

  testWidgets('a bare code pasted into the code field is left alone', (
    tester,
  ) async {
    // Not a link, so nothing is absorbed and the empty server field makes the dialog complain rather than guess.
    final result = await _pasteIntoDialog(tester, 'JUSTACODE');

    expect(result.chosen, isNull);
    expect(find.textContaining('server address'), findsOneWidget);
  });

  testWidgets('a pasted web address is refused in plain words and never '
      'becomes a request path', (tester) async {
    final result = await _pasteIntoDialog(
      tester,
      'https://chat.example/invite/abc234',
    );

    expect(result.chosen, isNull);
    expect(result.probed, isNull, reason: 'nothing was sent to any server');
    expect(find.textContaining('web address'), findsOneWidget);
    expect(find.textContaining('slimm://join'), findsOneWidget);
    expect(find.textContaining('server refused'), findsNothing);
  });

  testWidgets('a tapped invite link opens the redeem dialog prefilled and '
      'consumes itself', (tester) async {
    await _pumpWithTappedInvite(tester);

    expect(find.text('Joining chat.example'), findsOneWidget);
    var fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(1), reason: 'the link named the server');
    expect(fields[0].controller?.text, 'C1');

    await tester.tap(find.text('Use a different server'));
    await tester.pumpAndSettle();
    fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(2));
    expect(fields[0].controller?.text, 'https://chat.example:8443');
  });
}
