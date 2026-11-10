// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Closing the status sheet while its save is in flight must not throw, and the
/// profile the server answered with must still reach the member pane's copy.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/status_editor_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

void main() {
  testWidgets('a status saved after the sheet closed still updates the pane', (
    tester,
  ) async {
    final answer = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          SessionStore(
            tokens: const TokenPair(
              userId: 'self',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        mockApiOverride((request) async {
          await answer.future;
          return http.Response(
            jsonEncode({
              'id': 'self',
              'username': 'self',
              'display_name': 'Self',
              'created_at': 0,
              'status_text': 'heads down',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
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
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showStatusEditorSheet(context, ''),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await pumpFrames(tester, frames: 20);

    await tester.enterText(find.bySubtype<TextField>(), 'heads down');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    Navigator.of(tester.element(find.text('open'))).pop();
    await pumpFrames(tester, frames: 20);
    answer.complete();
    await pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(
      container.read(memberProfileOverridesProvider)['self']?.statusText,
      'heads down',
    );
  });
}
