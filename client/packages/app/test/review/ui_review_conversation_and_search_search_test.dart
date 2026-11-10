// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finding messages: the in-channel search bar (wide) and page (phone), the
/// command palette, and the link that opens a channel on one message.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/features/palette/widgets/command_palette.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart' show AppInput;

import '../ui_snapshot_support.dart';
import 'ui_review_conversation_and_search_data.dart';
import 'ui_review_conversation_and_search_router.dart';
import 'ui_review_conversation_and_search_support.dart';

const _channelSearch = '/channels/c-general/messages/search';

ReviewServe _hits(String path, List<Object> body) =>
    (request) => request.url.path == path ? jsonOk(body) : null;

ReviewServe _slowSearch(String path) =>
    (request) => request.url.path == path ? hangUntilTeardown() : null;

ReviewServe _brokenSearch(String path) =>
    (request) => request.url.path == path
    ? http.Response('{"error":"search is down"}', 500)
    : null;

/// Opens the search from the bar that carries it, then types [query] when there is one.
ReviewAct _inChannelSearch([String? query]) => (rig) async {
  rig.enableSemantics();
  await rig.settle();
  await rig.tapByLabel('Search messages');
  if (query == null) return;
  final label = rig.isPhone ? 'Search #general' : 'Search this channel';
  await rig.typeInto(
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label),
    query,
  );
};

const _people = [
  api.UserProfile(
    id: 'p-kiki',
    username: 'kiki',
    displayName: 'Kiki',
    createdAt: 0,
    roles: ['Moderator'],
  ),
  api.UserProfile(
    id: 'p-modlog',
    username: 'modlog',
    displayName: 'Mod Log',
    createdAt: 0,
    isBot: true,
  ),
  api.UserProfile(
    id: 'p-automod',
    username: 'automod',
    displayName: 'Automod',
    createdAt: 0,
    isBot: true,
  ),
];

Future<void> _seedPalette(MessageStore store) async {
  await store.upsertCategory(
    const api.ChannelCategory(
      id: 'cat-mod',
      name: 'Moderation',
      position: 2,
      createdAt: 0,
    ),
  );
  await store.upsertChannels(const [
    api.Channel(
      id: 'c-automod',
      name: 'automod-log',
      kind: 'text',
      createdAt: 1,
      categoryId: 'cat-mod',
    ),
    api.Channel(
      id: 'c-modlog',
      name: 'modlog',
      kind: 'text',
      createdAt: 2,
      categoryId: 'cat-mod',
    ),
    api.Channel(
      id: 'c-moderators',
      name: 'moderators',
      kind: 'text',
      createdAt: 3,
      categoryId: 'cat-mod',
    ),
  ]);
}

List<Object> _paletteHits() => [
  messageJson(
    api.Message(
      id: 'm-gap',
      channelId: 'c-modlog',
      authorId: 'user-nick',
      authorDisplayName: 'Nick',
      seq: 1,
      content: 'weird gap log from mod bot, it skipped everything after 03:10',
      createdAt: DateTime(2026, 10, 14).millisecondsSinceEpoch,
      editedAt: null,
    ),
  ),
  messageJson(
    api.Message(
      id: 'm-queue',
      channelId: 'c-general',
      authorId: 'user-ada',
      authorDisplayName: 'Ada Lovelace',
      seq: 9,
      content: 'The mod queue is empty, nothing was flagged since lunch.',
      createdAt: DateTime(2026, 11, 2).millisecondsSinceEpoch,
      editedAt: null,
    ),
  ),
];

ReviewAct _palette(String query) => (rig) async {
  unawaited(openCommandPalette(rig.shellContext));
  await rig.settle();
  await rig.typeInto(find.byKey(const Key('command-palette-input')), query);
};

void main() {
  setUpAll(loadRealFonts);

  const wide = [ReviewViewport.desktop];
  const phone = [ReviewViewport.phone];

  reviewCase(
    'search-channel-bar-wide',
    state: 'empty',
    viewports: wide,
    messages: fullTranscript,
    act: _inChannelSearch(),
  );
  reviewCase(
    'search-channel-bar-wide',
    state: 'results',
    viewports: wide,
    messages: fullTranscript,
    serve: _hits(_channelSearch, releaseHits()),
    act: _inChannelSearch('release'),
  );
  reviewCase(
    'search-channel-bar-wide',
    state: 'no-results',
    viewports: wide,
    messages: fullTranscript,
    serve: _hits(_channelSearch, const []),
    act: _inChannelSearch('zzzq'),
  );
  reviewCase(
    'search-channel-bar-wide',
    state: 'loading',
    viewports: wide,
    messages: fullTranscript,
    overrides: () => [reducedMotion()],
    serve: _slowSearch(_channelSearch),
    act: _inChannelSearch('release'),
  );
  reviewCase(
    'search-channel-bar-wide',
    state: 'error',
    viewports: wide,
    messages: fullTranscript,
    serve: _brokenSearch(_channelSearch),
    act: _inChannelSearch('release'),
  );

  reviewCase(
    'search-channel-compact',
    state: 'empty',
    viewports: phone,
    messages: fullTranscript,
    act: _inChannelSearch(),
  );
  reviewCase(
    'search-channel-compact',
    state: 'results',
    viewports: phone,
    messages: fullTranscript,
    serve: _hits(_channelSearch, releaseHits()),
    act: _inChannelSearch('release'),
  );
  reviewCase(
    'search-channel-compact',
    state: 'no-results',
    viewports: phone,
    messages: fullTranscript,
    serve: _hits(_channelSearch, const []),
    act: _inChannelSearch('zzzq'),
  );

  // The flash holds for under a second, so each theme gets its own mount and the frame is taken inside that hold.
  for (final theme in bothThemes) {
    reviewCase(
      'route-message-deep-link',
      state: 'highlighted',
      router: () => reviewRouter('/channels/c-general/m/m-20'),
      messages: fullTranscript,
      themes: [theme],
      settleFrames: 0,
      act: (rig) => rig.pumpFor(100),
      drain: const Duration(seconds: 4),
    );
  }
  reviewCase(
    'route-message-deep-link',
    state: 'not-loaded',
    router: () => reviewRouter('/channels/c-general/m/m-missing'),
    messages: fullTranscript,
  );

  reviewCase(
    'search-palette-wide',
    state: 'results',
    viewports: wide,
    overrides: () => [membersProvider.overrideWith((ref) async => _people)],
    seed: _seedPalette,
    serve: _hits('/search/messages', _paletteHits()),
    act: _palette('mod'),
  );
  reviewCase(
    'search-palette-wide',
    state: 'no-results',
    viewports: wide,
    overrides: () => [membersProvider.overrideWith((ref) async => _people)],
    seed: _seedPalette,
    serve: _hits('/search/messages', const []),
    act: _palette('zzzq'),
  );
  reviewCase(
    'search-palette-wide',
    state: 'messages-loading',
    viewports: wide,
    overrides: () => [membersProvider.overrideWith((ref) async => _people)],
    seed: _seedPalette,
    serve: _slowSearch('/search/messages'),
    act: _palette('mod'),
  );

  reviewCase(
    'search-palette-compact',
    state: 'results',
    viewports: phone,
    overrides: () => [membersProvider.overrideWith((ref) async => _people)],
    seed: _seedPalette,
    serve: _hits('/search/messages', _paletteHits()),
    act: _palette('mod'),
  );
  reviewCase(
    'search-palette-compact',
    state: 'no-results',
    viewports: phone,
    overrides: () => [membersProvider.overrideWith((ref) async => _people)],
    seed: _seedPalette,
    serve: _hits('/search/messages', const []),
    act: _palette('zzzq'),
  );
}
