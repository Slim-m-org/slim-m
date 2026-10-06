// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A retry from the create-channel or create-category sheet after a lost
/// response must replay the same client id, so the server's idempotent create
/// returns the first row instead of making a second one.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/create_category_sheet.dart';
import 'package:slimm_app/src/widgets/create_channel_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

Future<List<Map<String, dynamic>>> _submitTwice(
  WidgetTester tester, {
  required void Function(BuildContext) open,
  required String placeholder,
  required String buttonLabel,
}) async {
  final bodies = <Map<String, dynamic>>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: api.SessionStore(tokens: _tokens),
            httpClient: MockClient((request) async {
              bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response('{"error":"nope"}', 400);
            }),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byWidgetPredicate(
      (w) => w is AppInput && w.placeholder == placeholder,
    ),
    'lounge',
  );
  await tester.pump();
  for (var i = 0; i < 2; i++) {
    await tester.runAsync(() async {
      await tester.tap(find.text(buttonLabel));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }
  return bodies;
}

void main() {
  testWidgets('the channel sheet sends one id across a retry', (tester) async {
    final bodies = await _submitTwice(
      tester,
      open: (c) => showCreateChannelSheet(c, initialKind: 'text'),
      placeholder: 'Channel name',
      buttonLabel: 'Create channel',
    );

    expect(bodies, hasLength(2));
    expect(bodies[0]['id'], isA<String>());
    expect(bodies[1]['id'], bodies[0]['id']);
  });

  testWidgets('the category sheet sends one id across a retry', (tester) async {
    final bodies = await _submitTwice(
      tester,
      open: showCreateCategorySheet,
      placeholder: 'Category name',
      buttonLabel: 'Create category',
    );

    expect(bodies, hasLength(2));
    expect(bodies[0]['id'], isA<String>());
    expect(bodies[1]['id'], bodies[0]['id']);
  });
}
