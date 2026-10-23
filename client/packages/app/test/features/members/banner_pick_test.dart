// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The banner picker used to drop a pick silently: every early return in
/// `_choose` looked like a cancel, so on iPhone the sheet closed and nothing
/// changed. Each failure now says so; only a real cancel stays quiet.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/banner_settings_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../composer/composer_harness.dart' show FakePlatformFile, usePicker;

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _gif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// The bytes of a HEIC file: an `ftyp` box the engine cannot decode.
final _heic = Uint8List.fromList([
  0, 0, 0, 24, ...'ftypheic'.codeUnits, ...List.filled(40, 7), //
]);

Future<List<String>> _open(
  WidgetTester tester, {
  required Uint8List? picked,
  Object? failure,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  usePicker(
    picked == null ? null : FakePlatformFile('photo.img', picked),
    failure: failure,
  );
  final requests = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        requests.add('${request.method} ${request.url.path}');
        const json = {'content-type': 'application/json'};
        if (request.url.path == '/me') {
          final me = {
            'id': 'self',
            'username': 'self',
            'display_name': 'Self',
            'created_at': 0,
            'permissions': 0,
          };
          return http.Response(jsonEncode(me), 200, headers: json);
        }
        if (request.url.path == '/me/banner') {
          final profile = {
            'id': 'self',
            'username': 'self',
            'display_name': 'Self',
            'created_at': 0,
          };
          return http.Response(jsonEncode(profile), 200, headers: json);
        }
        return http.Response('', 404);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: BannerSettingsRow()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const Key('banner-image-tile')));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump(const Duration(milliseconds: 50));
    }
  });
  return requests;
}

void main() {
  testWidgets('a picked gif goes straight to the banner upload', (
    tester,
  ) async {
    final requests = await _open(tester, picked: Uint8List.fromList(_gif));
    expect(requests, contains('POST /me/banner'));
    expect(find.byType(AppErrorState), findsNothing);
  });

  testWidgets(
    'a picked still opens the crop sheet, and Cancel uploads nothing',
    (tester) async {
      final requests = await _open(tester, picked: Uint8List.fromList(_png));
      expect(find.text('Use picture'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(requests, isNot(contains('POST /me/banner')));
      expect(find.byType(AppErrorState), findsNothing);
    },
  );

  testWidgets('a HEIC the engine cannot decode says so instead of closing', (
    tester,
  ) async {
    final requests = await _open(tester, picked: _heic);
    expect(find.textContaining('not supported'), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.text('Use picture'), findsNothing);
    expect(requests, isNot(contains('POST /me/banner')));
  });

  testWidgets('a picker that throws says so', (tester) async {
    await _open(
      tester,
      picked: null,
      failure: PlatformException(code: 'photo_access_denied'),
    );
    expect(find.textContaining('Could not open that photo'), findsOneWidget);
  });

  testWidgets('a cancelled pick stays quiet', (tester) async {
    final requests = await _open(tester, picked: null);
    expect(find.byType(AppErrorState), findsNothing);
    expect(requests, isNot(contains('POST /me/banner')));
  });
}
