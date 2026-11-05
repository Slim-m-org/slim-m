// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rig that mounts the theme editor in a router, with the network, the
/// file picker and the file saver replaced.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';
import 'package:slimm_app/src/features/settings/screens/theme_editor_screen.dart';
import 'package:slimm_app/src/features/settings/screens/themes_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

class EditorRig {
  EditorRig({
    this.publishStatus = 201,
    this.publishMessage = '',
    this.storeThemes = const [],
  });

  final List<Map<String, dynamic>> storeThemes;

  final int publishStatus;
  final String publishMessage;
  final calls = <String>[];
  Object? published;
  final saved = <(String, List<int>)>[];
  ThemeFilePick? pick;

  late final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      apiProvider.overrideWith(
        (ref) => testApi((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.method == 'POST') {
            published = jsonDecode(request.body);
            if (publishStatus != 201) {
              return jsonHttpResponse({'error': publishMessage}, publishStatus);
            }
            return jsonHttpResponse({
              'id': 'new',
              'name': 'Posted',
              'author_id': 'self',
              'author_name': 'Self',
              'created_at': 1,
              'has_picture': false,
              'theme': published,
            }, 201);
          }
          if (request.url.path == '/space/themes') {
            return jsonHttpResponse({
              'themes': storeThemes,
              'default_theme_id': null,
            });
          }
          return http.Response('', 204);
        }),
      ),
      meProvider.overrideWith(
        (ref) async => const api.Me(
          id: 'self',
          username: 'self',
          displayName: 'Self',
          createdAt: 0,
          permissions: 0,
        ),
      ),
      themeFileSaverProvider.overrideWithValue((name, bytes) async {
        saved.add((name, bytes));
        return true;
      }),
      themeFilePickerProvider.overrideWithValue(() async => pick),
    ],
  );

  Future<void> pump(
    WidgetTester tester, {
    ThemeEditorSeed? seed,
    Size size = const Size(1000, 900),
    String location = Routes.personalThemeEditor,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: location,
      initialExtra: seed,
      routes: [
        GoRoute(
          path: Routes.personalThemes,
          builder: (_, _) => const ThemesScreen(),
        ),
        GoRoute(
          path: Routes.personalThemeEditor,
          builder: (_, state) =>
              ThemeEditorScreen(seed: state.extra as ThemeEditorSeed?),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: router,
        ),
      ),
    );
    await settle(tester);
  }
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// A document that fails the contrast floors: primary text the colour of the surfaces.
ThemeDocument failingDocument() {
  final base = themeBases['dark']!;
  final document = ThemeDocument.of(
    base,
    name: 'Faint',
    author: '',
    base: 'dark',
    brightness: Brightness.dark,
  );
  return document.copyWith(
    colours: {...document.colours, 'textPrimary': base.surfaceBase},
  );
}
