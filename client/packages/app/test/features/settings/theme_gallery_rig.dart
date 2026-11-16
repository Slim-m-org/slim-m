// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes gallery mounted in the Appearance pane over a fake store: who
/// is signed in, what the Space lists, and every request it sent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_gallery.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'settings_sub_page_host.dart';

const pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

ThemeDocument galleryDoc(
  String name, {
  AppTokens tokens = AppTokens.forest,
  String base = 'forest',
}) => ThemeDocument.of(
  tokens,
  name: name,
  author: 'Ren',
  base: base,
  brightness: Brightness.dark,
);

/// A file whose primary text is the colour of its surfaces.
Map<String, dynamic> failingFile(String name) {
  final document = galleryDoc(name);
  return document
      .copyWith(
        colours: {
          ...document.colours,
          'textPrimary': document.colours['surfaceBase']!,
        },
      )
      .toJson();
}

Map<String, dynamic> stored(
  String id,
  String name, {
  String? author,
  bool picture = false,
  Map<String, dynamic>? file,
}) => {
  'id': id,
  'name': name,
  'author_id': author,
  'author_name': 'Ren',
  'created_at': 1,
  'has_picture': picture,
  'theme': file ?? galleryDoc(name).toJson(),
};

class GalleryRig {
  GalleryRig({
    this.permissions = 0,
    this.defaultId,
    this.storeFails = false,
    this.deletesDrop = false,
    List<Map<String, dynamic>>? themes,
  }) : themes =
           themes ??
           [
             stored('t1', 'Pine', author: 'ren'),
             stored('t2', 'Mine', author: 'self'),
           ];

  final int permissions;
  final String? defaultId;
  final bool storeFails;

  /// Delete requests die on the wire, as they do when the network drops.
  final bool deletesDrop;
  final List<Map<String, dynamic>> themes;
  final calls = <String>[];
  Object? lastBody;
  final saved = <(String, List<int>)>[];
  ThemeFilePick? pick;

  /// Holds the file picker open until a test completes it.
  Completer<ThemeFilePick?>? pickGate;

  late final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      apiProvider.overrideWith((ref) => testApi(_answer)),
      meProvider.overrideWith(
        (ref) async => api.Me(
          id: 'self',
          username: 'self',
          displayName: 'Self',
          createdAt: 0,
          permissions: permissions,
        ),
      ),
      themeFileSaverProvider.overrideWithValue((name, bytes) async {
        saved.add((name, bytes));
        return true;
      }),
      themeFilePickerProvider.overrideWithValue(
        () => pickGate?.future ?? Future.value(pick),
      ),
    ],
  );

  Future<http.Response> _answer(http.Request request) async {
    calls.add('${request.method} ${request.url.path}');
    if (request.body.isNotEmpty) lastBody = jsonDecode(request.body);
    if (deletesDrop && request.method == 'DELETE') {
      throw http.ClientException('socket closed', request.url);
    }
    if (request.url.path == '/space/themes' && request.method == 'GET') {
      if (storeFails) return http.Response('', 500);
      return jsonHttpResponse({
        'themes': themes,
        'default_theme_id': defaultId,
      });
    }
    if (request.url.path.endsWith('/picture')) {
      return http.Response.bytes(
        base64Decode(pixelPng),
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    if (request.method == 'POST') {
      return jsonHttpResponse(stored('new', 'Posted'), 201);
    }
    return http.Response('', 204);
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1000, 2400),
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
          home: settingsSubPageHost(() => [themesSubPage()]),
        ),
      ),
    );
    await settleGallery(tester);
  }
}

/// Past the sub-page's fade and a menu's or sheet's entrance.
Future<void> settleGallery(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await revealInGallery(tester, finder);
  await tester.tap(finder);
  await settleGallery(tester);
}

/// Scrolls the gallery until [finder] is on screen, when it is a card or a
/// button on the page rather than an item in a menu or sheet above it.
Future<void> revealInGallery(WidgetTester tester, Finder finder) async {
  final list = find.byKey(const Key('themes-page-list'));
  if (list.evaluate().isEmpty) return;
  final onPage =
      finder.evaluate().isEmpty ||
      find.descendant(of: list, matching: finder).evaluate().isNotEmpty;
  if (!onPage) return;
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: list,
          matching: find.byWidgetPredicate((w) => w is Scrollable),
        )
        .first,
  );
  await tester.pump();
}
