// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes page (decision 0106): listing, applying, importing, publishing,
/// and who sees remove and "Set as Space default" in a row's menu.
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/resolved_theme.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store_actions.dart';
import 'package:slimm_app/src/features/settings/screens/themes_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_list_row.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map<String, dynamic> _file(String name) => ThemeDocument.of(
  AppTokens.forest,
  name: name,
  author: 'Ren',
  base: 'forest',
  brightness: Brightness.dark,
).toJson();

Map<String, dynamic> _stored(
  String id,
  String name, {
  String? author,
  bool picture = false,
}) => {
  'id': id,
  'name': name,
  'author_id': author,
  'author_name': 'Ren',
  'created_at': 1,
  'has_picture': picture,
  'theme': _file(name),
};

class _Rig {
  _Rig({
    this.permissions = 0,
    this.defaultId,
    this.picker,
    this.storeFails = false,
    List<Map<String, dynamic>>? themes,
  }) : themes =
           themes ??
           [
             _stored('t1', 'Pine', author: 'ren'),
             _stored('t2', 'Mine', author: 'self'),
           ];

  final int permissions;
  final String? defaultId;
  final Future<ThemeParse?> Function()? picker;
  final bool storeFails;
  final List<Map<String, dynamic>> themes;
  final calls = <String>[];
  Object? lastBody;

  late final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (picker != null) themeFilePickerProvider.overrideWithValue(picker!),
      apiProvider.overrideWith(
        (ref) => testApi((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.body.isNotEmpty) lastBody = jsonDecode(request.body);
          if (request.url.path == '/space/themes' && request.method == 'GET') {
            if (storeFails) return http.Response('', 500);
            return jsonHttpResponse({
              'themes': themes,
              'default_theme_id': defaultId,
            });
          }
          if (request.url.path.endsWith('/picture')) {
            return http.Response.bytes(
              base64Decode(_pixelPng),
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          if (request.method == 'POST') {
            return jsonHttpResponse(_stored('new', 'Posted'), 201);
          }
          return http.Response('', 204);
        }),
      ),
      meProvider.overrideWith(
        (ref) async => api.Me(
          id: 'self',
          username: 'self',
          displayName: 'Self',
          createdAt: 0,
          permissions: permissions,
        ),
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester, _Rig rig) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(rig.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: rig.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const ThemesScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _menuOf(String id) => find.descendant(
  of: find.byKey(Key('theme-store-$id')),
  matching: find.byKey(ThemeListRow.menuButtonKey),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _openRowMenu(WidgetTester tester, String id) async {
  await tester.tap(_menuOf(id));
  await _settle(tester);
}

Future<void> _openPageMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('themes-menu')));
  await _settle(tester);
}

Future<void> _pickMenu(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await _settle(tester);
}

void main() {
  testWidgets('a member may apply themes and remove only their own', (
    tester,
  ) async {
    final rig = _Rig();
    await _pump(tester, rig);

    expect(find.byKey(const Key('theme-store-t1')), findsOneWidget);
    expect(find.byKey(const Key('theme-store-t2')), findsOneWidget);

    await _openRowMenu(tester, 't1');
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Set as Space default'), findsNothing);
    expect(find.text('Export'), findsOneWidget);
    await _pickMenu(tester, 'Export');

    await _openRowMenu(tester, 't2');
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('an administrator removes any theme and sets the default', (
    tester,
  ) async {
    final rig = _Rig(permissions: Perm.manageServer, defaultId: 't1');
    await _pump(tester, rig);

    expect(find.byKey(ThemeListRow.defaultBadgeKey), findsOneWidget);

    await _openRowMenu(tester, 't1');
    expect(find.text('Clear default'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await _settle(tester);

    await _openRowMenu(tester, 't2');
    await _pickMenu(tester, 'Set as Space default');
    expect(rig.calls, contains('PUT /space/default-theme'));
    expect(rig.lastBody, {'theme_id': 't2'});
  });

  testWidgets('removing a theme asks the server to delete it', (tester) async {
    final rig = _Rig(permissions: Perm.manageServer);
    await _pump(tester, rig);

    await _openRowMenu(tester, 't1');
    await _pickMenu(tester, 'Remove');
    expect(rig.calls, contains('DELETE /space/themes/t1'));
  });

  testWidgets('tapping a store theme makes it the custom theme in use', (
    tester,
  ) async {
    final rig = _Rig();
    await _pump(tester, rig);

    await tester.tap(find.byKey(const Key('theme-store-t1')));
    await _settle(tester);

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.custom);
    expect(rig.container.read(customThemeProvider)!.name, 'Pine');
    expect(rig.container.read(customThemeProvider)!.base, 'forest');
  });

  testWidgets('tapping a built-in theme selects it', (tester) async {
    final rig = _Rig();
    await _pump(tester, rig);

    await tester.tap(find.byKey(const Key('theme-builtin-forest')));
    await _settle(tester);

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.forest);
  });

  testWidgets('a store theme with a picture shows a thumbnail', (tester) async {
    final rig = _Rig(
      themes: [_stored('p1', 'Photo', author: 'ren', picture: true)],
    );
    await _pump(tester, rig);
    expect(find.byKey(const Key('theme-preview-picture')), findsOneWidget);
    expect(rig.calls, contains('GET /space/themes/p1/picture'));
  });

  testWidgets('publishing the current theme posts a valid theme file', (
    tester,
  ) async {
    final rig = _Rig();
    await _pump(tester, rig);

    await _openPageMenu(tester);
    await _pickMenu(tester, 'Publish current theme');

    expect(rig.calls, contains('POST /space/themes'));
    final body = rig.lastBody! as Map<String, dynamic>;
    expect(parseThemeJson(body).problems, isEmpty);
    expect(body['author'], 'Self');
  });

  testWidgets('an unusable import shows its problems and applies nothing', (
    tester,
  ) async {
    final bad = _file('Bad');
    (bad['tokens'] as Map<String, dynamic>)['textPrimary'] = '#12151A';
    final rig = _Rig(picker: () async => parseThemeJson(bad));
    await _pump(tester, rig);

    await _openPageMenu(tester);
    await _pickMenu(tester, 'Import file');

    expect(find.byKey(const Key('theme-import-problems')), findsOneWidget);
    expect(find.textContaining('textPrimary on surfaceBase'), findsOneWidget);
    expect(find.byKey(const Key('theme-import-ready')), findsNothing);
    expect(
      rig.container.read(themeControllerProvider),
      isNot(AppThemeChoice.custom),
    );
  });

  testWidgets('a good import asks first, and applying keeps it', (
    tester,
  ) async {
    final rig = _Rig(picker: () async => parseThemeJson(_file('Imported')));
    await _pump(tester, rig);

    await _openPageMenu(tester);
    await _pickMenu(tester, 'Import file');
    expect(find.byKey(const Key('theme-import-ready')), findsOneWidget);
    expect(find.text('Use this theme?'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Apply'));
    await _settle(tester);

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.custom);
    expect(rig.container.read(customThemeProvider)!.name, 'Imported');
    expect(find.byKey(const Key('theme-import-ready')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
      parseThemeFile(prefs.getString(customThemeKey)!).document!.name,
      'Imported',
    );
  });

  testWidgets('cancelling an import leaves the theme alone', (tester) async {
    final rig = _Rig(picker: () async => parseThemeJson(_file('Imported')));
    await _pump(tester, rig);

    await _openPageMenu(tester);
    await _pickMenu(tester, 'Import file');
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await _settle(tester);

    expect(rig.container.read(customThemeProvider), isNull);
    expect(rig.calls.where((c) => c.startsWith('POST')), isEmpty);
  });

  testWidgets('a store that will not load shows one error and no publish', (
    tester,
  ) async {
    final rig = _Rig(storeFails: true);
    await _pump(tester, rig);

    expect(find.byKey(const Key('themes-store-error')), findsOneWidget);
    await _openPageMenu(tester);
    expect(find.text('Publish current theme'), findsNothing);
    expect(find.text('Import file'), findsOneWidget);
    expect(find.text('Export current theme'), findsOneWidget);
  });

  test('a custom or Space default document is what the choice paints with', () {
    final doc = parseThemeJson(_file('Pine')).document!;
    for (final choice in [AppThemeChoice.custom, AppThemeChoice.spaceDefault]) {
      final resolved = resolveTheme(
        choice,
        custom: choice == AppThemeChoice.custom ? doc : null,
        spaceDefault: choice == AppThemeChoice.spaceDefault ? doc : null,
      );
      expect(resolved.dark.surfaceBase, doc.tokens.surfaceBase);
      expect(resolved.mode, ThemeMode.dark);
    }
    final missing = resolveTheme(AppThemeChoice.spaceDefault);
    expect(missing.mode, ThemeMode.system);
    expect(missing.dark.surfaceBase, AppTokens.dark.surfaceBase);
  });
}
