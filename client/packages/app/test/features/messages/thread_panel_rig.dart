// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One real transcript, mounted as the thread panel or as a channel, for the
/// suites that compare the two row for row.
///
/// Not a `_test.dart` file, so `flutter test` does not run it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_app/src/features/messages/widgets/thread_parent_card.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';
import 'message_row_harness.dart' as h;

const rigBase = 1700000000000;

/// A message by [author] at second [n]; [id] doubles as its text.
Message rigMessage(
  String id,
  int n,
  String author, {
  String? replyTo,
  String? content,
}) => Message(
  id: id,
  channelId: 'c1',
  authorId: author,
  authorDisplayName: author,
  seq: n,
  content: content ?? 'body $id',
  createdAt: rigBase + n * 1000,
  replyToId: replyTo,
  pending: false,
  failed: false,
);

/// A UUIDv7 whose leading 48 bits are [ms], as the server mints them.
String uuidV7At(int ms) {
  final hex = ms.toRadixString(16).padLeft(12, '0');
  return '${hex.substring(0, 8)}-${hex.substring(8)}-7000-8000-000000000001';
}

const rigParent = api.ThreadParent(
  parentChannelId: 'general',
  parentChannelName: 'general',
  parentMessageId: '018bcfe5-6800-7000-8000-000000000001',
  parentContent: '@nick planetarium arc might be coming to close soon.',
  parentAuthorId: 'taka',
  parentAuthorDisplayName: 'Taka',
);

class _Extras extends MessageExtrasController {
  _Extras(super.ref, Map<String, MessageExtras> seed) {
    state = seed;
  }
  @override
  void applyMessages(Iterable<api.Message> messages) {}
  @override
  void applyMessage(api.Message message) {}
}

Future<void> pumpRig(
  WidgetTester tester,
  List<Message> messages, {
  double width = 390,
  Brightness brightness = Brightness.light,
  bool thread = true,
  Map<String, MessageExtras> extras = const {},
  String? jumpTargetId,
  Widget? snapshotBoundary,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tokens = brightness == Brightness.dark
      ? AppTokens.dark
      : AppTokens.light;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'nick',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        liveEventsProvider.overrideWithValue(
          const Stream<api.ServerEvent>.empty(),
        ),
        mockApiOverride((request) async {
          final ids = request.url.path == '/users'
              ? request.url.queryParameters['ids']?.split(',') ?? const []
              : const <String>[];
          return http.Response(
            jsonEncode([
              for (final id in ids)
                {
                  'id': id,
                  'username': id,
                  'display_name': id[0].toUpperCase() + id.substring(1),
                  'created_at': 0,
                },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        membersProvider.overrideWith(
          (ref) async => const [
            api.UserProfile(
              id: 'nick',
              username: 'nick',
              displayName: 'Nick',
              createdAt: 0,
              roles: [],
            ),
          ],
        ),
        messageExtrasProvider.overrideWith((ref) => _Extras(ref, extras)),
      ],
      child: MaterialApp(
        theme: buildTheme(brightness, tokens),
        home: Scaffold(
          body: RepaintBoundary(
            key: const Key('ui_snapshot_boundary'),
            child: ColoredBox(
              color: tokens.surfaceBase,
              child: MessageTranscript(
                channelId: 'c1',
                messages: messages,
                syncStatus: SyncStatus.live,
                historyKnown: true,
                channelName: thread ? null : 'general',
                channelIsThread: thread,
                threadParent: thread
                    ? const ThreadParentCard(
                        parent: rigParent,
                        threadChannelId: 'c1',
                      )
                    : null,
                jumpTargetId: jumpTargetId,
                jumpToken: jumpTargetId == null ? null : 1,
                scrollController: ScrollController(),
                lastReadSeq: 999999,
                selfId: 'nick',
                knownUsernames: const {},
                customEmoji: const {},
                history: const ChannelHistory(atStart: true),
                onLoadOlder: () {},
                onRetryOlder: () {},
                actionsFor: (_, _) => h.noActions,
                onRetry: (_) {},
                onDiscard: (_) {},
                onPickReaction: (_, _) {},
                onReactionTap: (_, _) {},
                onVote: (_, _) {},
                onSubmitEdit: (_, _) {},
                onCancelEdit: () {},
                onJumpToReply: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Runs out the jump highlight's hold and fade so no timer outlives the test.
Future<void> settleRig(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
}
