// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invite landing card comes from a server nobody has vouched for: it
/// names the host, pairs the Space with the code that was checked, and draws
/// that server's pictures only within a byte and pixel bound.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/invite_dialog.dart';
import 'package:slimm_app/src/features/auth/widgets/invite_preview_image.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/pixel_bomb_png.dart';

const _usable = {
  'usable': true,
  'community': {
    'name': 'Home',
    'member_count': 3,
    'invited_by': 'Nia',
    'uses_remaining': null,
    'expires_at': null,
    'description': '',
    'banner_updated_at': null,
    'icon_updated_at': null,
  },
};

Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

final _drawn = find.byWidgetPredicate((w) => w is RawImage);

Future<void> _pumpDialog(WidgetTester tester, http.Client client) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        probeApiProvider.overrideWithValue(
          (baseUrl) =>
              SlimmApi(baseUrl: baseUrl, httpClient: client, unvouched: true),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: InviteDialog()),
      ),
    ),
  );
  await pumpFrames(tester);
}

Future<void> _pumpImage(WidgetTester tester, Uint8List served) async {
  final client = MockClient(
    (request) async => http.Response.bytes(served, 200),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        probeApiProvider.overrideWithValue(
          (baseUrl) =>
              SlimmApi(baseUrl: baseUrl, httpClient: client, unvouched: true),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: SizedBox.square(
          dimension: 64,
          child: InvitePreviewImage(
            server: Uri.parse('https://unvouched.example'),
            fetch: (client, maxBytes) =>
                client.fetchInviteIcon('CODE1', maxBytes: maxBytes),
            maxSide: 64,
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await pumpFrames(tester);
}

void main() {
  testWidgets('the landing card names the host it came from', (tester) async {
    await _pumpDialog(
      tester,
      MockClient(
        (request) async => http.Response(
          jsonEncode(_usable),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );
    await tester.enterText(_field('Server'), 'https://chat.example:8443');
    await tester.enterText(_field('Invite code'), 'CODE1');
    await tester.tap(find.text('I accept the terms of use for this Space.'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await pumpFrames(tester, frames: 40);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('chat.example:8443'), findsOneWidget);
  });

  testWidgets('a code edited while it is checked is not paired with that '
      'answer', (tester) async {
    final reply = Completer<http.Response>();
    await _pumpDialog(tester, MockClient((request) => reply.future));
    await tester.enterText(_field('Server'), 'https://chat.example');
    await tester.enterText(_field('Invite code'), 'CODE1');
    await tester.tap(find.text('I accept the terms of use for this Space.'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await pumpFrames(tester);

    await tester.enterText(_field('Invite code'), 'CODE2');
    reply.complete(
      http.Response(
        jsonEncode(_usable),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    await pumpFrames(tester, frames: 20);

    expect(find.text('Home'), findsNothing);
    expect(find.text('Join'), findsNothing);
  });

  testWidgets('a small invite image is drawn', (tester) async {
    await _pumpImage(tester, pixelBombPng(16));
    expect(_drawn, findsOneWidget);
  });

  testWidgets('an invite image past the byte cap is never decoded', (
    tester,
  ) async {
    final padded = BytesBuilder()
      ..add(pixelBombPng(16))
      ..add(Uint8List(inviteImageMaxBytes));
    await _pumpImage(tester, padded.toBytes());
    expect(_drawn, findsNothing);
  });

  testWidgets('an invite image declaring a huge canvas is refused', (
    tester,
  ) async {
    await _pumpImage(tester, pixelBombPng(8192));
    expect(_drawn, findsNothing);
  });
}
