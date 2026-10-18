// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One recording harness for the Space settings Configuration panes' option
/// tests: a widget under a real provider scope whose API answers from
/// [ConfigHarness.handler] and remembers every request it was sent.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class SentRequest {
  SentRequest(this.method, this.path, this.body);

  final String method;
  final String path;
  final Object? body;

  @override
  String toString() => '$method $path ${jsonEncode(body)}';
}

http.Response jsonOk(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> roleJson(
  String id,
  String name, {
  int permissions = 0,
  bool everyone = false,
}) => {
  'id': id,
  'name': name,
  'permissions': permissions,
  'is_everyone': everyone,
  'mentionable': false,
  'hoist': false,
  'created_at': 0,
};

class ConfigHarness {
  ConfigHarness({this.handler});

  /// Answers a request, or null for the default (an empty list, 200).
  final http.Response? Function(http.Request request)? handler;

  final sent = <SentRequest>[];

  /// Requests that changed something, in order.
  List<SentRequest> get writes => sent.where((r) => r.method != 'GET').toList();

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child, {
    List<Override> overrides = const [],
    Size size = const Size(900, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        modulePermissionsProvider.overrideWith((ref) async => const []),
        mockApiOverride((request) async {
          final text = request.body;
          sent.add(
            SentRequest(
              request.method,
              request.url.path,
              text.isEmpty ? null : jsonDecode(text),
            ),
          );
          return handler?.call(request) ??
              (request.method == 'GET'
                  ? jsonOk(<Object>[])
                  : http.Response('', 204));
        }),
        membersProvider.overrideWith((ref) async => const []),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }
}
