// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space theme store in Appearance (decision 0106): listing, applying,
/// importing, publishing, and who sees remove and "Make Space default".
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
import 'package:slimm_app/src/features/settings/widgets/theme_store_card.dart';
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
        home: Scaffold(body: ListView(children: const [ThemeStoreCard()])),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _button(String label) => find.widgetWithText(AppButton, label);

void main() {
  testWidgets(
    'a member sees the themes, may apply them and remove only their own',
    (tester) async {
      final rig = _Rig();
      await _pump(tester, rig);

      expect(find.byKey(const Key('theme-store-t1')), findsOneWidget);
      expect(find.byKey(const Key('theme-store-t2')), findsOneWidget);
      expect(_button('Apply'), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const Key('theme-store-t1')),
          matching: _button('Remove'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('theme-store-t2')),
          matching: _button('Remove'),
        ),
        findsOneWidget,
      );
      expect(_button('Make Space default'), findsNothing);
    },
  );

  testWidgets(
    'an administrator removes any theme and sets or clears the default',
    (tester) async {
      final rig = _Rig(permissions: Perm.manageServer, defaultId: 't1');
      await _pump(tester, rig);

      expect(_button('Remove'), findsNWidgets(2));
      expect(
        find.byKey(const Key('theme-store-default-badge')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('theme-store-t1')),
          matching: _button('Clear default'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('theme-store-t2')),
          matching: _button('Make Space default'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(rig.calls, contains('PUT /space/default-theme'));
      expect(rig.lastBody, {'theme_id': 't2'});
    },
  );

  testWidgets('removing a theme asks the server to delete it', (tester) async {
    final rig = _Rig(permissions: Perm.manageServer);
    await _pump(tester, rig);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('theme-store-t1')),
        matching: _button('Remove'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(rig.calls, contains('DELETE /space/themes/t1'));
  });

  testWidgets('applying a store theme makes it the custom theme in use', (
    tester,
  ) async {
    final rig = _Rig();
    await _pump(tester, rig);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('theme-store-t1')),
        matching: _button('Apply'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.custom);
    expect(rig.container.read(customThemeProvider)!.name, 'Pine');
    expect(rig.container.read(customThemeProvider)!.base, 'forest');
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

    await tester.tap(_button('Publish'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(rig.calls, contains('POST /space/themes'));
    final body = rig.lastBody! as Map<String, dynamic>;
    expect(parseThemeJson(body).problems, isEmpty);
    expect(body['author'], 'Self');
  });

  testWidgets(
    'an unusable import shows its problems inline and applies nothing',
    (tester) async {
      final bad = _file('Bad');
      (bad['tokens'] as Map<String, dynamic>)['textPrimary'] = '#12151A';
      final rig = _Rig(picker: () async => parseThemeJson(bad));
      await _pump(tester, rig);

      await tester.tap(_button('Import'));
      await tester.pump();

      expect(find.byKey(const Key('theme-import-problems')), findsOneWidget);
      expect(find.textContaining('textPrimary on surfaceBase'), findsOneWidget);
      expect(find.byKey(const Key('theme-import-ready')), findsNothing);
      expect(
        rig.container.read(themeControllerProvider),
        isNot(AppThemeChoice.custom),
      );
    },
  );

  testWidgets('a good import is offered to apply, and applying keeps it', (
    tester,
  ) async {
    final rig = _Rig(picker: () async => parseThemeJson(_file('Imported')));
    await _pump(tester, rig);

    await tester.tap(_button('Import'));
    await tester.pump();
    expect(find.byKey(const Key('theme-import-ready')), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('theme-import-ready')),
        matching: _button('Apply'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(rig.container.read(themeControllerProvider), AppThemeChoice.custom);
    expect(rig.container.read(customThemeProvider)!.name, 'Imported');
    expect(find.byKey(const Key('theme-import-ready')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
      parseThemeFile(prefs.getString(customThemeKey)!).document!.name,
      'Imported',
    );
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
