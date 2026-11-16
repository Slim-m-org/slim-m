// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rig that mounts the theme editor above Themes in the Appearance pane,
/// with the network, the file picker and the file saver replaced; [EditorRig.open]
/// puts it in the real settings modal with a second pane and search.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_editor_page.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_gallery.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'settings_sub_page_host.dart';

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
      toastsProvider.overrideWith((ref) => _HeldToasts()),
    ],
  );

  /// What the editor said in toasts, oldest first.
  List<String> get toasts => [
    for (final toast in container.read(toastsProvider)) toast.message,
  ];

  /// Opens settings as the app does, a modal over a channel, on Appearance
  /// with Themes and the editor pushed; a second pane and a search entry for
  /// it sit in the nav.
  Future<void> open(
    WidgetTester tester, {
    ThemeEditorSeed? seed,
    Size size = laptop,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(container.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/settings'),
              child: const Text('channel'),
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (context, _) => modalPage(context, _settings(seed)),
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
    await tester.tap(find.text('channel'));
    await settle(tester);
  }

  /// [editor] false opens Themes alone, the page the editor sits above.
  Future<void> pump(
    WidgetTester tester, {
    ThemeEditorSeed? seed,
    Size size = const Size(1000, 900),
    bool editor = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: settingsSubPageHost(
            () => [themesSubPage(), if (editor) themeEditorSubPage(seed)],
          ),
        ),
      ),
    );
    await settle(tester);
  }
}

/// Keeps every toast until read, so none leaves a dismissal timer behind.
class _HeldToasts extends ToastsController {
  @override
  int show(
    String message, {
    AppToastSeverity severity = AppToastSeverity.info,
    Duration duration = ToastsController.defaultDuration,
  }) => super.show(message, severity: severity, duration: Duration.zero);
}

/// The laptop the editor is judged at, and the phone.
const laptop = Size(1280, 900);
const phone = Size(390, 844);

const _editorPage = 'editor';

Widget _settings(ThemeEditorSeed? seed) => SettingsPanesScaffold(
  title: 'Settings',
  backTooltip: 'Back to channels',
  backFallback: '/',
  initialPaneId: 'appearance',
  initialPageId: _editorPage,
  searchEntries: const [SettingsEntry('other', 'Other setting')],
  groups: [
    SettingsPaneGroup(
      label: 'App',
      panes: [
        SettingsPane(
          id: 'appearance',
          label: 'Appearance',
          builder: (_) => const Text('appearance pane'),
          subPages: {
            _editorPage: () => [themesSubPage(), themeEditorSubPage(seed)],
          },
        ),
        SettingsPane(
          id: 'other',
          label: 'Other',
          builder: (_) => const Text('other pane'),
        ),
      ],
    ),
  ],
);

Finder byKey(String key) => find.byKey(Key(key));

/// Brings [finder] into view, then taps it and lets the result land.
Future<void> tapIn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(finder);
  await settle(tester);
}

/// Picks [label] from the editor's kebab, anchored or as a sheet.
Future<void> pickFromMenu(WidgetTester tester, String label) async {
  await tapIn(tester, byKey('theme-editor-menu'));
  await tester.tap(find.text(label));
  await settle(tester);
}

/// The footer's buttons are on and the draft can be saved.
bool saveEnabled(WidgetTester tester) =>
    !tester.widget<AppButton>(byKey('theme-editor-save')).disabled &&
    !tester.widget<AppButton>(byKey('theme-editor-apply')).disabled;

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
