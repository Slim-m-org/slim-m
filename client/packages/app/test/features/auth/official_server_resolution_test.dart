// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Google's automated Android runs must land on the review server, never prod.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

TestLabChannel _channel({required bool android, Object? answer}) {
  const name = MethodChannel('top.npcserver.slimm/test_lab');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(name, (call) async {
        if (answer is PlatformException) throw answer;
        return answer;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(name, null),
  );
  return TestLabChannel(channel: name, isAndroid: android);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveOfficialServer', () {
    test('a test lab device gets the review server', () async {
      final resolved = await resolveOfficialServer(
        testLab: _channel(android: true, answer: true),
      );
      expect(resolved, Uri.parse(reviewServer));
    });

    test('a normal phone keeps the compiled-in server', () async {
      final resolved = await resolveOfficialServer(
        testLab: _channel(android: true, answer: false),
      );
      expect(resolved, Uri.parse(officialServer));
    });

    test(
      'another platform never asks and keeps the compiled-in server',
      () async {
        final resolved = await resolveOfficialServer(
          testLab: _channel(android: false, answer: true),
        );
        expect(resolved, Uri.parse(officialServer));
      },
    );

    test('a failing native check keeps the compiled-in server', () async {
      final resolved = await resolveOfficialServer(
        testLab: _channel(android: true, answer: PlatformException(code: 'x')),
      );
      expect(resolved, Uri.parse(officialServer));
    });
  });

  test('isOfficialServer compares against the resolved address', () {
    final review = Uri.parse(reviewServer);
    expect(isOfficialServer(Uri.parse('$reviewServer/'), review), isTrue);
    expect(isOfficialServer(Uri.parse(officialServer), review), isFalse);
  });

  testWidgets('Join the official Space goes to the resolved server', (
    tester,
  ) async {
    final probed = <String>[];
    final httpClient = MockClient((request) async {
      probed.add(request.url.host);
      return http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'identity': {
            'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'fingerprint': 'deadbeefcafebabefeedface1337d00d',
            'fingerprint_groups': ['dead'],
            'color_strip': [0, 1, 2, 3],
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    Uri? chosen;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        officialServerProvider.overrideWithValue(Uri.parse(reviewServer)),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: OnboardingScreen(
            onServerChosen: (server, invite) => chosen = server,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(Uri.parse(reviewServer).host), findsOneWidget);

    await tester.tap(find.text('Join the official Space'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(chosen, Uri.parse(reviewServer));
    expect(probed, isNotEmpty);
    expect(probed.toSet(), {Uri.parse(reviewServer).host});
  });
}
