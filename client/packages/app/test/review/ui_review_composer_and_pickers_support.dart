// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the composer-and-pickers review suites share: seeded providers for
/// the composer's own data, a fake GIF source, and the finders and typing
/// seams of the real composer in the channel shell.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/favorites/providers/favorite_preview_bytes.dart';
import 'package:slimm_app/src/features/favorites/providers/favorites_controller.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';

import '../ui_snapshot_support.dart';
import 'review_support.dart' show reviewThemes;
import 'ui_review_composer_and_pickers_tiles.dart';

/// The composer's picker and Space emoji seeded; the emoji tiles are real
/// images, so a Space emoji reads as one. [spaceEmoji] false is a Space with none.
List<Override> composerSeeds({bool gifs = true, bool spaceEmoji = true}) => [
  serverInfoProvider.overrideWith(
    (ref) async => api.Version(
      name: 'slim-m',
      version: '0.127.0',
      protocol: 1,
      gifSearchEnabled: gifs,
    ),
  ),
  customEmojiProvider.overrideWith(
    (ref) async => [
      for (final name in spaceEmoji ? _spaceEmoji : const <String>[])
        api.CustomEmoji(
          id: 'e-$name',
          name: name,
          uploaderId: 'user-ada',
          createdAt: 1,
        ),
    ],
  ),
  customEmojiImageProvider.overrideWith(
    (ref, id) async => tilePng(48, 48, tintOf(id)),
  ),
];

const _spaceEmoji = [
  'smug_cat',
  'small_win',
  'party_parrot',
  'shipit',
  'big_brain',
  'lgtm',
  'rubber_duck',
  'coffee_time',
];

/// The fixture server plus a GIF source with canned answers: [trending] on
/// open, [found] for any search, and an empty list for the query `no-match`.
/// [extra] answers first, for the one route a case needs to bend.
class ReviewServer {
  ReviewServer({
    this.trending = _gifTitles,
    this.found = _gifTitles,
    this.failTrending = false,
    this.failSearch = false,
    this.extra,
  });

  final List<String> trending;
  final List<String> found;
  final bool failTrending;
  final bool failSearch;
  final Future<http.Response>? Function(http.Request request)? extra;

  Future<http.Response> handle(http.Request request) async {
    final custom = extra?.call(request);
    if (custom != null) return custom;
    final path = request.url.path;
    if (path == '/gifs/trending') {
      return failTrending
          ? _error(502, 'the GIF provider is down')
          : _list(trending);
    }
    if (path == '/gifs/search') {
      if (failSearch) return _error(502, 'the GIF provider is down');
      final query = request.url.queryParameters['q'] ?? '';
      return _list(query == 'no-match' ? const [] : found);
    }
    if (path.startsWith('/gifs/preview/')) {
      final id = path.substring('/gifs/preview/'.length);
      return http.Response.bytes(
        tilePng(160, 120, tintOf(id)),
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    return fixtureResponse(request);
  }

  http.Response _list(List<String> titles) => http.Response(
    jsonEncode({
      'results': [
        for (final (i, title) in titles.indexed)
          {'id': 'gif-$i-$title', 'title': title, 'width': 320, 'height': 240},
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String message) =>
      jsonResponse({'error': message}, status);

  /// Replaces the fixture api with one that answers these routes too.
  Override get override => apiProvider.overrideWith((ref) {
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient(handle),
    );
    ref.onDispose(client.close);
    return client;
  });
}

/// A JSON answer, the shape every route of the real server replies in.
http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

const _gifTitles = [
  'happy dance',
  'thumbs up',
  'slow clap',
  'facepalm',
  'mind blown',
  'cheers',
  'nope',
  'celebrate',
];

/// The caller's favorites: a GIF, a kept image and a video, newest first.
class SeededFavorites extends FavoritesController {
  SeededFavorites(this.entries);

  final List<api.Favorite> entries;

  @override
  Future<List<api.Favorite>> build() async => entries;
}

api.Favorite favorite(
  String id,
  String title, {
  api.FavoriteKind kind = api.FavoriteKind.gif,
  String? contentType,
}) => api.Favorite(
  id: id,
  kind: kind,
  title: title,
  width: 100,
  height: 100,
  available: true,
  createdAt: 1,
  attachmentId: kind == api.FavoriteKind.attachment
      ? id.codeUnitAt(1).toRadixString(16) * 32
      : null,
  contentType: contentType,
);

/// [entries] empty is the "nothing kept yet" state; both still draw the tab.
List<Override> favoriteSeeds(List<api.Favorite> entries) => [
  favoritesProvider.overrideWith(() => SeededFavorites(entries)),
  favoritePreviewBytesProvider.overrideWith(
    (ref, id) async => tilePng(100, 100, tintOf(id)),
  ),
  attachmentPreviewBytesProvider.overrideWith(
    (ref, key) async => tilePng(100, 100, tintOf('$key')),
  ),
];

/// Runs [capture] with real shadow blur, once per theme on a fresh mount.
///
/// The framework disables shadow blur in every widget test, and a capture
/// only re-enables it for the one boundary it reads, so a shadow inside a
/// nested repaint boundary (a menu above the composer, a sheet's route) is
/// painted hard-edged and reads as a solid band. Painting the whole mount
/// with the flag off keeps each nested layer blurred, but the capture turns
/// the flag back on after the first theme, hence one mount per theme.
Future<void> reviewShadowed(
  Future<void> Function(List<String> themes) capture,
) async {
  if (!writingSnapshots) return capture(reviewThemes);
  for (final theme in reviewThemes) {
    debugDisableShadows = false;
    try {
      await capture([theme]);
    } finally {
      debugDisableShadows = true;
    }
  }
}

/// The composer bar, the container every composer finder starts from.
final composerBar = find.byKey(const Key('composer-action-bar'));

/// The composer's text field, whatever the message shell around it.
final composerField = find.descendant(
  of: composerBar,
  matching: find.byWidgetPredicate((w) => w is TextField),
);

/// Types into the composer the way a paste or an IME does: the controller
/// gets the text and a caret at its end, so the autocomplete sees a trigger.
Future<void> typeInComposer(WidgetTester tester, String text) async {
  final controller = tester.widget<TextField>(composerField).controller!;
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  await settle(tester);
}

/// Pumps the frames a popover, sheet or fetch needs to land, with real time
/// in the middle for an image decode, without waiting on animations that
/// never settle.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump(const Duration(milliseconds: 350));
}

/// Lets a debounced request and its reply finish: real time for the fake
/// network, then fake time for the frames that draw the result.
Future<void> settleRequest(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await settle(tester);
  await settle(tester);
}
