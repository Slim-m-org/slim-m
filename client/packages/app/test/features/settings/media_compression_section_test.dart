// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The photo compression controls on the retention and limits pane: the
/// switch reveals the options, each control patches only its own field, and a
/// refused change stays on screen as an error, never a snackbar.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/media_compression_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _defaults = ['jpg', 'jpeg', 'heic', 'heif', 'png', 'webp', 'bmp', 'tiff'];

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Widget _app(MockClient client) => ProviderScope(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final built = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: client,
      );
      ref.onDispose(built.close);
      return built;
    }),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: const Scaffold(
      body: SingleChildScrollView(child: MediaCompressionSection()),
    ),
  ),
);

/// A server holding one settings object that PATCH merges into.
MockClient _server({
  bool enabled = false,
  List<String> extensions = _defaults,
  List<Map<String, dynamic>>? patches,
  bool refusePatch = false,
}) {
  final state = <String, dynamic>{
    'enabled': enabled,
    'extensions': extensions,
    'default_extensions': _defaults,
    'supported_extensions': [..._defaults, 'jpe', 'tif'],
    'metadata': 'remove_location',
    'keep_original': false,
  };
  return MockClient((request) async {
    if (request.method == 'PATCH') {
      if (refusePatch) {
        return _json({'error': 'extension is not supported'}, 400);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      patches?.add(body);
      state.addAll(body);
      if ((state['extensions'] as List).isEmpty) {
        state['extensions'] = _defaults;
      }
    }
    return _json(state);
  });
}

void main() {
  testWidgets('the options appear only while compression is on', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_server()));
    await tester.pumpAndSettle();

    expect(find.text('Compress photos'), findsOneWidget);
    expect(find.text('File types'), findsNothing);
    expect(find.text('Photo metadata'), findsNothing);
    expect(find.text('Keep originals'), findsNothing);

    await tester.pumpWidget(_app(_server(enabled: true)));
    await tester.pumpAndSettle();

    expect(find.text('File types'), findsOneWidget);
    expect(find.text('Photo metadata'), findsOneWidget);
    expect(find.text('Keep originals'), findsOneWidget);
    expect(find.text('Restore defaults'), findsNothing);
  });

  testWidgets('the switch patches only enabled', (tester) async {
    final patches = <Map<String, dynamic>>[];
    await tester.pumpWidget(_app(_server(patches: patches)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();

    expect(patches, [
      {'enabled': true},
    ]);
    expect(find.text('File types'), findsOneWidget);
  });

  testWidgets('each option patches only its own field', (tester) async {
    final patches = <Map<String, dynamic>>[];
    await tester.pumpWidget(_app(_server(enabled: true, patches: patches)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppToggle).last);
    await tester.pumpAndSettle();

    expect(patches, [
      {'metadata': 'remove_all'},
      {'keep_original': true},
    ]);
  });

  testWidgets(
    'typed file types are saved as a list, defaults restored with an empty one',
    (tester) async {
      final patches = <Map<String, dynamic>>[];
      await tester.pumpWidget(_app(_server(enabled: true, patches: patches)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), 'png, JPG  heic');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save types'));
      await tester.pumpAndSettle();
      expect(patches.single, {
        'extensions': ['png', 'JPG', 'heic'],
      });

      await tester.pumpWidget(
        _app(_server(enabled: true, extensions: ['png'], patches: patches)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore defaults'));
      await tester.pumpAndSettle();
      expect(patches.last, {'extensions': <String>[]});
    },
  );

  testWidgets('a refused change shows a persistent error, not a snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_server(refusePatch: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  test('typed text splits on commas, spaces and semicolons', () {
    expect(parseExtensions('jpg, png;heic  webp,,'), [
      'jpg',
      'png',
      'heic',
      'webp',
    ]);
    expect(parseExtensions('  '), isEmpty);
  });
}
