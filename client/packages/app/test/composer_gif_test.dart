// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The GIF picker's composer wiring: absent entirely on a deployment with no
/// provider configured (the acceptance the job this closes was built
/// against - zero UI, zero network calls), present and reachable on one that
/// offers it, at both touch and pointer density, ending in an ordinary
/// staged attachment a send may reference.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

/// The smallest possible real GIF (a 1x1 transparent pixel), so `Image.memory`
/// actually decodes it rather than falling back to an error builder.
final _gifBytes = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);

/// Answers `/version` with [gifSearchEnabled] and, unless [failOnGifRequest]
/// is set, a full working GIF picker flow: one trending result shown on
/// open, one search result, its preview, and a select that stores it as an
/// ordinary attachment. [failOnGifRequest] is the acceptance proof itself -
/// a deployment reporting no provider must never have anything call one of
/// these routes at all.
api.SlimmApi Function(Ref) _apiWithGifs({
  required bool gifSearchEnabled,
  bool failOnGifRequest = false,
  bool emptyResults = false,
  bool searchFails = false,
  bool trendingFails = false,
}) {
  return (ref) => api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: ref.watch(sessionProvider),
    httpClient: MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '0.39.0',
            'protocol': 1,
            'gif_search_enabled': gifSearchEnabled,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.startsWith('/gifs/')) {
        if (failOnGifRequest) {
          fail('a request reached $path while gif search is off');
        }
        if (request.method == 'GET' && path == '/gifs/trending') {
          if (trendingFails) {
            return http.Response(
              jsonEncode({'error': 'the provider could not be reached'}),
              503,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'id': 'tok-trending',
                  'title': 'a trending gif',
                  'width': 200,
                  'height': 150,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/gifs/search') {
          if (searchFails) {
            return http.Response(
              jsonEncode({'error': 'the provider could not be reached'}),
              503,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'results': emptyResults
                  ? <Object?>[]
                  : [
                      {
                        'id': 'tok-1',
                        'title': 'a cat waving',
                        'width': 200,
                        'height': 150,
                      },
                    ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            (path == '/gifs/preview/tok-1' ||
                path == '/gifs/preview/tok-trending')) {
          return http.Response.bytes(
            _gifBytes,
            200,
            headers: {'content-type': 'image/gif'},
          );
        }
        if (request.method == 'POST' && path == '/gifs/select') {
          return http.Response(
            jsonEncode({
              'id': 'gif-attachment-id',
              'filename': 'gif.gif',
              'content_type': 'image/gif',
              'size': _gifBytes.length,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
      }
      if (request.method == 'GET' && path == '/attachments/gif-attachment-id') {
        return http.Response.bytes(
          _gifBytes,
          200,
          headers: {'content-type': 'image/gif'},
        );
      }
      return http.Response('{}', 404, headers: {'content-type': 'text/plain'});
    }),
  );
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets(
    'the desktop GIF button is absent, and nothing calls /gifs, when no provider is configured',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: _apiWithGifs(
            gifSearchEnabled: false,
            failOnGifRequest: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(emojiButton);
      await tester.pumpAndSettle();
      expect(gifTab, findsNothing);
    },
  );

  testWidgets(
    'the desktop GIF button appears and opens the picker on trending results, not a blank grid',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: _apiWithGifs(gifSearchEnabled: true),
        ),
      );
      await tester.pumpAndSettle();

      await openGifTab(tester);

      final tile = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Pick: a trending gif',
      );
      expect(tile, findsOneWidget);
    },
  );

  testWidgets(
    'a failed trending fetch shows an inline error, not a silent blank grid',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: _apiWithGifs(gifSearchEnabled: true, trendingFails: true),
        ),
      );
      await tester.pumpAndSettle();

      await openGifTab(tester);

      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  testWidgets(
    'touch density folds GIF into the actions sheet only when a provider is configured',
    (tester) async {
      // Touch density, and so the sheet at all, follows width; see AppTouchTargets.of.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.android,
          apiBuilder: _apiWithGifs(gifSearchEnabled: true),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(moreActionsButton);
      await tester.pumpAndSettle();
      expect(find.text('GIF'), findsOneWidget);
    },
  );

  testWidgets(
    'touch density has no GIF row at all without a configured provider',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.android,
          apiBuilder: _apiWithGifs(
            gifSearchEnabled: false,
            failOnGifRequest: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(moreActionsButton);
      await tester.pumpAndSettle();
      expect(find.text('GIF'), findsNothing);
    },
  );

  testWidgets(
    'picking a search result stages it as an already-uploaded attachment, ready to send',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: _apiWithGifs(gifSearchEnabled: true),
        ),
      );
      await tester.pumpAndSettle();

      await openGifTab(tester);

      await tester.enterText(find.byType(TextField).last, 'cat');
      // Past the composer's own search debounce.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      final tile = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Pick: a cat waving',
      );
      expect(tile, findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      // The sheet closed and the picked GIF is staged, exactly like an upload.
      expect(find.text('gif.gif'), findsOneWidget);

      await tester.tap(sendButton);
      await tester.pumpAndSettle();

      expect(sends.count, 1);
      expect(sends.ids, ['gif-attachment-id']);
    },
  );

  testWidgets('a query with no results says so, plainly', (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _apiWithGifs(gifSearchEnabled: true, emptyResults: true),
      ),
    );
    await tester.pumpAndSettle();

    await openGifTab(tester);
    await tester.enterText(find.byType(TextField).last, 'nothing at all');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('No matches.'), findsOneWidget);
  });

  testWidgets('a failed search shows an inline error, not a silent gap', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _apiWithGifs(gifSearchEnabled: true, searchFails: true),
      ),
    );
    await tester.pumpAndSettle();

    await openGifTab(tester);
    await tester.enterText(find.byType(TextField).last, 'cat');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
  });

  EditableText composerField(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText).first);

  testWidgets('/gif cat opens the GIF tab searching for cat, field focused', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _apiWithGifs(gifSearchEnabled: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '/gif cat');
    await tester.pump();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(controller.text, isEmpty, reason: 'the command is not sent');
    expect(sends.count, 0);
    final search = tester.widget<EditableText>(find.byType(EditableText).last);
    expect(search.controller.text, 'cat');
    expect(search.focusNode.hasFocus, isTrue);
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Pick: a cat waving',
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking a GIF puts the cursor back in the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _apiWithGifs(gifSearchEnabled: true),
      ),
    );
    await tester.pumpAndSettle();

    // The mouse route: open the panel, type in its search, pick.
    await openGifTab(tester);
    await tester.tap(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, 'cat');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(composerField(tester).focusNode.hasFocus, isFalse);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Pick: a cat waving',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('gif.gif'), findsOneWidget);
    expect(composerField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('with no GIF provider, /gif is just text', (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _apiWithGifs(
          gifSearchEnabled: false,
          failOnGifRequest: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '/gif cat');
    await tester.pump();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();
    expect(sends.count, 1);
  });
}
