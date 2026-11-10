// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What every messages review suite shares: the real conversation shell at a
/// review viewport, seeded with a transcript, held open while a case acts on
/// it, and captured once per theme from one mount.
///
/// Names follow `<surface>[--<state>]--<viewport>-<theme>` and are built here
/// only, so a suite cannot spell one differently.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore;
import 'package:slimm_design_system/design_system.dart';

import '../support/fake_sync.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'review_support.dart' as review;
import 'ui_review_messages_api.dart';

export 'ui_review_messages_api.dart' show reviewApi, reviewReactor;

/// The two windows a review captures; a desktop narrower than 1280 would
/// switch the app to its touch layout and review the wrong thing.
const reviewViewports = {'phone': Size(390, 844), 'desktop': Size(1280, 800)};

const reviewThemes = ['dark', 'light'];

String reviewPngName(
  String surface,
  String? state,
  String viewport,
  String theme,
) => review.reviewName(surface, state, viewport, theme);

const _day = 1753600000000;

/// Answers every attachment fetch, original and preview, from [byId].
List<Override> mediaOverrides(Map<String, Uint8List> byId) => [
  attachmentBytesProvider.overrideWith((ref, id) async => byId[id]!),
  attachmentPreviewBytesProvider.overrideWith(
    (ref, key) async => byId[key.id]!,
  ),
];

/// A message in `c-general`, [seq] minutes after the fixture's first one.
api.Message reviewMessage(
  int seq,
  String author,
  String content, {
  String? replyToId,
  List<api.ReactionSummary> reactions = const [],
  List<api.Attachment> attachments = const [],
  List<api.CodeRun> codeRuns = const [],
  List<api.Embed> embeds = const [],
  List<api.ComponentRow> components = const [],
  api.Poll? poll,
  api.CallRecord? call,
  api.ForwardedMessage? forwarded,
  api.ViaModule? viaModule,
  String? webhookUsername,
  bool mentionsMe = false,
  int? editedAt,
  String? channelId,
}) => api.Message(
  id: 'r-$seq',
  channelId: channelId ?? 'c-general',
  authorId: author,
  authorDisplayName: reviewAuthors[author],
  seq: seq,
  content: content,
  createdAt: _day + seq * 60000,
  editedAt: editedAt,
  replyToId: replyToId,
  reactions: reactions,
  attachments: attachments,
  codeRuns: codeRuns,
  embeds: embeds,
  components: components,
  poll: poll,
  call: call,
  forwarded: forwarded,
  viaModule: viaModule,
  webhookUsername: webhookUsername,
  mentionsMe: mentionsMe,
);

const reviewAuthors = {
  'user-nick': 'Nick',
  'user-ada': 'Ada Lovelace',
  'user-long-name': 'Christoph Bartholomew Fitzgerald-Huang III',
  'user-bot': 'Reminder Bot',
  'user-hook': 'Deploy Hook',
};

/// What a case can reach once the shell is up: the container, the real
/// navigator's context (to open a sheet from) and a live [WidgetRef].
class ReviewScene {
  ReviewScene(this.tester, this.container, this.router);

  final WidgetTester tester;
  final ProviderContainer container;
  final GoRouter router;
  WidgetRef? _ref;

  WidgetRef get ref => _ref!;

  BuildContext get context =>
      router.routerDelegate.navigatorKey.currentState!.overlay!.context;

  Future<MessageStore> get store => container.read(storeProvider.future);

  /// A window of real time, for an image decode the fake clock never finishes.
  Future<void> decode([int millis = 250]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: millis)),
    );
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> frames([int count = 3]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 350));
    }
  }
}

typedef SceneStep = Future<void> Function(ReviewScene scene);

/// Mounts [route] (the general channel unless a case needs another) at
/// [viewport] with [messages] as its transcript, runs [seed] before the first
/// frame and [act] once it settles, then captures [surface] (and [state]) in
/// both themes. [release] runs after the last capture, for a request a case
/// held open to show a loading state.
Future<void> captureMessages(
  WidgetTester tester, {
  required String surface,
  required String viewport,
  String? state,
  required List<api.Message> messages,
  String route = '/channels/c-general',
  List<Override> overrides = const [],
  FutureOr<http.Response?> Function(http.Request request)? serve,
  SceneStep? seed,
  SceneStep? act,
  SceneStep? release,
  List<String> themes = reviewThemes,
}) async {
  tester.view.physicalSize = reviewViewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      syncControllerProvider.overrideWith(StubSyncController.new),
      reviewApi(serve),
      ...overrides,
    ],
    messages: messages,
  );
  final router = fixtureRouter(route);
  final scene = ReviewScene(tester, fixture.container, router);
  if (seed != null) await seed(scene);

  Widget build(String theme) => UncontrolledProviderScope(
    container: fixture.container,
    child: RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(
          snapshotThemes[theme]!.brightness,
          snapshotThemes[theme]!.tokens,
        ),
        routerConfig: router,
        builder: (context, child) => Consumer(
          builder: (context, ref, _) {
            scene._ref = ref;
            return appChromeBuilder(context, child);
          },
        ),
      ),
    ),
  );

  await tester.pumpWidget(build(themes.first));
  await tester.pump();
  await scene.frames(2);
  await scene.decode();
  if (act != null) {
    await act(scene);
    await scene.frames(2);
  }
  Object? firstException;
  for (final theme in themes) {
    if (theme != themes.first) {
      await tester.pumpWidget(build(theme));
      await scene.frames(2);
    }
    final name = reviewPngName(surface, state, viewport, theme);
    await expectSettled(tester, name);
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);
  if (release != null) await release(scene);
  await teardownFixture(tester, fixture.container, fixture.db);
}
