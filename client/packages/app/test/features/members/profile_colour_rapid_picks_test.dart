// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rapid colour picks end on the last one: the swatch moves at once, saves
/// queue behind the one in flight with only the newest kept, and a refused
/// save re-reads what the server holds instead of trusting a snapshot.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/profile_colour_field.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _names = ['Pink', 'Purple', 'Blue', 'Orange', 'Green', 'Magenta'];

class _Server {
  final saved = <int>[];
  var colour = 0;
  Completer<void>? hold;
  int? refuse;
}

Future<_Server> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        const json = {'content-type': 'application/json'};
        if (request.method == 'PATCH') {
          final index = (jsonDecode(request.body) as Map)['profile_color'];
          server.saved.add(index as int);
          await server.hold?.future;
          if (index == server.refuse) {
            return http.Response('{"error":"slow down"}', 429, headers: json);
          }
          server.colour = index;
        }
        return http.Response(
          jsonEncode({
            'id': 'self',
            'username': 'nc1107',
            'display_name': 'Nick',
            'created_at': 0,
            'permissions': 0,
            'profile_color': server.colour,
          }),
          200,
          headers: json,
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
        home: const Scaffold(body: ProfileColourField()),
      ),
    ),
  );
  await pumpFrames(tester);
  return server;
}

Finder _swatch(String name) => find.bySemanticsLabel('Profile colour: $name');

bool _selected(WidgetTester tester, String name) =>
    tester
        .getSemantics(_swatch(name))
        .getSemanticsData()
        .flagsCollection
        .isSelected ==
    Tristate.isTrue;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rapid picks show at once and save only the first and last', (
    tester,
  ) async {
    final server = await _pump(tester);
    server.hold = Completer();

    for (final name in ['Purple', 'Blue', 'Orange', 'Green']) {
      await tester.tap(_swatch(name));
      await tester.pump();
    }
    expect(_selected(tester, 'Green'), isTrue);

    server.hold!.complete();
    await pumpFrames(tester);

    expect(server.saved, [_names.indexOf('Purple'), _names.indexOf('Green')]);
    expect(server.colour, _names.indexOf('Green'));
    expect(_selected(tester, 'Green'), isTrue);
    expect(find.textContaining('Could not'), findsNothing);
  });

  testWidgets('a refused save shows the colour the server still holds', (
    tester,
  ) async {
    final server = await _pump(tester);
    server.refuse = _names.indexOf('Blue');

    await tester.tap(_swatch('Blue'));
    await pumpFrames(tester);

    expect(find.textContaining('Could not save the profile colour'), findsOne);
    expect(_selected(tester, 'Pink'), isTrue);
  });
}
