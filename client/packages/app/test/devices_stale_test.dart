// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The devices list files devices nobody has used for a while under "Not used
/// recently", never prints the loopback host name, and marks this device.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/devices_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

final _now = DateTime.now().millisecondsSinceEpoch;
const _day = 24 * 60 * 60 * 1000;

Map<String, dynamic> _device(
  String id,
  String name, {
  int? seen,
  String? kind,
  bool current = false,
}) => {
  'id': id,
  'name': name,
  'created_at': 0,
  'last_seen_at': seen,
  'client_kind': kind,
  'is_current': current,
};

Future<Set<String>> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> rows,
) async {
  final removed = <String>{};
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'u',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      apiProvider.overrideWith((ref) {
        final built = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'DELETE') {
              removed.add(request.url.pathSegments.last);
              return http.Response('', 204);
            }
            return http.Response(
              jsonEncode(
                rows.where((r) => !removed.contains(r['id'])).toList(),
              ),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: DevicesSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return removed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rows = [
    _device('1', 'iPhone', seen: _now, kind: 'ios', current: true),
    _device('2', 'Linux - fedora', seen: _now - 60 * 1000, kind: 'desktop'),
    _device('3', 'iOS (localhost)', seen: null, kind: 'ios'),
    _device('4', 'Linux (laptop)', seen: _now - 20 * _day, kind: 'desktop'),
  ];

  testWidgets('devices not used for a week sit under Not used recently', (
    tester,
  ) async {
    await _pump(tester, rows);

    expect(find.text('NOT USED RECENTLY'), findsOneWidget);
    final heading = tester.getTopLeft(find.text('NOT USED RECENTLY')).dy;
    expect(tester.getTopLeft(find.text('iPhone')).dy, lessThan(heading));
    expect(
      tester.getTopLeft(find.text('Linux - fedora')).dy,
      lessThan(heading),
    );
    expect(tester.getTopLeft(find.text('iOS')).dy, greaterThan(heading));
    expect(find.text('THIS DEVICE'), findsOneWidget);
  });

  testWidgets('no row ever prints the loopback host name', (tester) async {
    await _pump(tester, rows);
    expect(find.textContaining('localhost'), findsNothing);
  });

  testWidgets('one Sign out unused signs out only the stale devices', (
    tester,
  ) async {
    final removed = await _pump(tester, rows);

    await tester.tap(find.widgetWithText(AppButton, 'Sign out unused'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Sign out').last);
    await tester.pumpAndSettle();

    expect(removed, {'3', '4'});
    expect(find.text('NOT USED RECENTLY'), findsNothing);
    expect(find.text('Linux - fedora'), findsOneWidget);
  });

  testWidgets('with nothing stale there is no group', (tester) async {
    await _pump(tester, rows.sublist(0, 2));
    expect(find.text('NOT USED RECENTLY'), findsNothing);
    expect(find.widgetWithText(AppButton, 'Sign out unused'), findsNothing);
  });
}
