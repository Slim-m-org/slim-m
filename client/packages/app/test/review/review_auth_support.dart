// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the auth review suites share: a scripted server, the identities it
/// presents, and the few gestures that drive onboarding and sign-in.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../support/async_wait.dart';
import 'review_support.dart';

const authServer = 'https://chat.example';

const identityA = {
  'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  'fingerprint': 'deadbeefcafebabefeedface1337d00d',
  'fingerprint_groups': [
    'dead',
    'beef',
    'cafe',
    'babe',
    'feed',
    'face',
    '1337',
    'd00d',
  ],
  'color_strip': [0, 1, 2, 3],
};

const identityB = {
  'public_key': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  'fingerprint': 'facefeedf00dd00dfacefeedf00dd00d',
  'fingerprint_groups': [
    'face',
    'feed',
    'f00d',
    'd00d',
    'face',
    'feed',
    'f00d',
    'd00d',
  ],
  'color_strip': [4, 5, 0, 1],
};

/// A server that answers `/version` and a modern safety set.
const modernVersion = {
  'name': 'slim-m',
  'version': '0.17.0',
  'protocol': 1,
  'space_name': 'Lamplight',
  'capabilities': ['report', 'block'],
};

String identityHandle(String server) => 'server_identity:$server';

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

/// Answers `/version`, the invite check and the auth calls from tables a case
/// fills in; [hold] and [versionHold] park a reply for good, which is how a case
/// captures the in-flight state.
class ScriptedServer {
  ScriptedServer({
    this.version = modernVersion,
    this.checkBody = const {'usable': false},
    this.checkStatus = 200,
    this.checkFails = false,
    this.versionFails = false,
    this.hold,
    this.versionHold,
    this.auth,
    this.reset,
    this.resetHold,
  });

  final Map<String, Object?> version;
  final Map<String, Object?> checkBody;
  final int checkStatus;
  final bool checkFails;
  final bool versionFails;
  final Completer<void>? hold;

  /// Parks the `/version` probe, which is what onboarding's identity step waits on.
  final Completer<void>? versionHold;

  /// Answers `/auth/login` and `/auth/register`; null leaves both at a plain 200.
  final http.Response Function(http.Request request)? auth;

  /// Answers `/auth/reset`; null accepts the code with a 204.
  final http.Response Function(http.Request request)? reset;
  final Completer<void>? resetHold;

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/version') {
      await versionHold?.future;
      if (versionFails) throw Exception('connection refused');
      return jsonResponse(version);
    }
    if (path == '/auth/reset') {
      await resetHold?.future;
      return reset?.call(request) ?? http.Response('', 204);
    }
    if (path.endsWith('/check')) {
      await hold?.future;
      if (checkFails) throw Exception('connection refused');
      return jsonResponse(checkBody, checkStatus);
    }
    if (auth != null && (path == '/auth/login' || path == '/auth/register')) {
      return auth!(request);
    }
    return http.Response('{}', 200);
  });
}

/// The probe seam and the api both pointed at [server]'s scripted answers.
List<Override> authOverrides(
  ScriptedServer server, {
  KeyStore? keyStore,
  String address = authServer,
  bool signInApi = false,
}) => [
  keyStoreProvider.overrideWithValue(keyStore ?? InMemoryKeyStore()),
  serverUrlProvider.overrideWith((ref) => Uri.parse(address)),
  probeApiProvider.overrideWithValue(
    (baseUrl) => api.SlimmApi(baseUrl: baseUrl, httpClient: server.client),
  ),
  if (signInApi)
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: ref.watch(serverUrlProvider),
        session: ref.watch(sessionProvider),
        httpClient: server.client,
      );
      ref.onDispose(client.close);
      return client;
    }),
];

/// A key store that already pins [key] for [address].
Future<KeyStore> pinnedKeyStore(
  String key, {
  String address = authServer,
}) async {
  final store = InMemoryKeyStore();
  await store.put(identityHandle(address), key);
  return store;
}

/// The [AppInput] a person would call [label], found without naming its type.
Finder inputLabelled(String label) => find.byWidgetPredicate(
  (w) => w is AppInput && w.semanticLabel == label,
  description: 'input labelled "$label"',
);

/// Lets a tap's frames and a mocked reply land, then the 350ms entrance.
Future<void> settleReview(WidgetTester tester) async {
  await pumpFrames(tester, frames: 6);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> tapLabel(WidgetTester tester, String label) async {
  final target = find.text(label);
  expect(target, findsOneWidget, reason: 'nothing says "$label" to tap');
  await tester.tap(target);
  await settleReview(tester);
}

Future<void> typeInto(WidgetTester tester, String label, String text) async {
  await tester.enterText(inputLabelled(label), text);
  await tester.pump();
}

const termsLabel = 'I accept the terms of use for this Space.';

/// Runs [capture] with a reply parked on [hold], then lets it go: a request
/// still out when the test ends leaves its 45s timeout armed, which fails it.
Future<void> whileHolding(
  WidgetTester tester,
  Completer<void> hold,
  Future<void> Function() capture,
) async {
  await capture();
  hold.complete();
  await tester.pump();
}

/// Onboarding as the account switcher's "Add a server" and a first install both mount it.
Widget onboardingScreen(BuildContext context) =>
    OnboardingScreen(onServerChosen: (server, invite) {});

/// Opens "Connect to a Space", types [address] and presses Continue.
ReviewAct submitManualAddress(String address) => (tester, handles) async {
  await tapLabel(tester, 'Connect to a Space');
  await typeInto(tester, 'Server address', address);
  await tapLabel(tester, 'Continue');
};
