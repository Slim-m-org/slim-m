// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Moving someone between calls: the menu row and its destinations, dragging
/// in the rail, and the moved account following to the new call.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/rail_participant_drag.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_voice_participants.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_move_follower.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_api.dart';
import '../../support/menu_gestures.dart';
import 'voice_controller_harness.dart' show FakeSession;

const _bob = VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _bobProfile = api.UserProfile(
  id: 'user-bob',
  username: 'bob',
  displayName: 'Bob',
  createdAt: 0,
);

const _tokens = api.TokenPair(
  userId: 'user-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Map<String, Object?> _channel(String id, String name, {int limit = 0}) => {
  'id': id,
  'name': name,
  'kind': 'voice',
  'created_at': 0,
  'permissions': Perm.moveMembers | Perm.viewChannel,
  'user_limit': limit,
};

class _Wire {
  final posts = <http.Request>[];

  Future<http.Response> handle(http.Request request) async {
    final json = {'content-type': 'application/json'};
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/move')) {
      posts.add(request);
      return http.Response('', 204);
    }
    if (path == '/channels') {
      final body = [
        _channel('voice-1', 'Lobby'),
        _channel('voice-2', 'Games'),
        _channel('voice-3', 'Tiny', limit: 1),
      ];
      return http.Response(jsonEncode(body), 200, headers: json);
    }
    if (path == '/channels/voice-3/voice/roster') {
      final body = {
        'participants': [
          {'user_id': 'someone', 'display_name': 'Someone'},
        ],
      };
      return http.Response(jsonEncode(body), 200, headers: json);
    }
    if (path.endsWith('/voice/roster')) {
      return http.Response(
        jsonEncode({'participants': <Object>[]}),
        200,
        headers: json,
      );
    }
    return http.Response('{}', 404);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Wire wire, {
  required int permissions,
  Widget? beside,
  RoleLadder? ladder,
  api.UserProfile bob = _bobProfile,
  api.Me? me,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride(wire.handle),
        userProfileProvider('user-bob').overrideWith((ref) async => bob),
        membersProvider.overrideWith((ref) async => [bob]),
        myPermissionsProvider.overrideWithValue(permissions),
        if (ladder != null) roleLadderProvider.overrideWithValue(ladder),
        if (me != null) meProvider.overrideWith((ref) async => me),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: FakeSession()),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(
                width: 240,
                child: RailParticipantList(
                  participants: [_bob],
                  channelId: 'voice-1',
                ),
              ),
              ?beside,
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _gamesKey = Key('games-drop');

const _games = RailMoveDropTarget(
  key: _gamesKey,
  channelId: 'voice-2',
  child: SizedBox(width: 200, height: 60),
);

/// Carries Bob with a mouse from his rail row onto [_games].
Future<void> _dragBobOntoGames(WidgetTester tester) async {
  final target = tester.getCenter(find.byKey(_gamesKey));
  final bob = tester.getCenter(find.text('Bob'));
  final drag = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await drag.addPointer(location: bob);
  await tester.pump();
  await drag.down(bob);
  await drag.moveTo(target - const Offset(20, 0));
  await tester.pump();
  await drag.moveTo(target);
  await drag.up();
  await tester.pumpAndSettle();
  await drag.removePointer();
}

void main() {
  testWidgets('a mover sees Move to, anyone else does not', (tester) async {
    await _pump(tester, _Wire(), permissions: Perm.moveMembers);
    await rightClickMenu(tester, find.text('Bob'));
    expect(find.text('Move to...'), findsOneWidget);

    await _pump(tester, _Wire(), permissions: 0);
    await rightClickMenu(tester, find.text('Bob'));
    expect(find.text('Move to...'), findsNothing);
  });

  testWidgets('Move to lists other voice channels, full ones disabled', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, wire, permissions: Perm.moveMembers);
    await rightClickMenu(tester, find.text('Bob'));
    await tester.tap(find.text('Move to...'));
    await tester.pumpAndSettle();

    expect(find.text('Lobby'), findsNothing, reason: 'where Bob already is');
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Full'), findsOneWidget);

    await tester.tap(find.text('Tiny'));
    await tester.pumpAndSettle();
    expect(wire.posts, isEmpty, reason: 'a full call cannot be chosen');

    await tester.tap(find.text('Games'));
    await tester.pumpAndSettle();
    expect(wire.posts, hasLength(1));
    expect(
      wire.posts.single.url.path,
      '/channels/voice-1/voice/participants/user-bob/move',
    );
    expect(jsonDecode(wire.posts.single.body), {'to_channel_id': 'voice-2'});
  });

  testWidgets('dragging a person onto another channel moves them', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, wire, permissions: Perm.moveMembers, beside: _games);
    await _dragBobOntoGames(tester);

    expect(wire.posts, hasLength(1));
    expect(jsonDecode(wire.posts.single.body), {'to_channel_id': 'voice-2'});
  });

  testWidgets('only a person below you on the role ladder can be dragged', (
    tester,
  ) async {
    const ladder = RoleLadder(permissions: Perm.moveMembers, topPosition: 5);
    for (final (top, owner, moved) in [
      (4, false, true),
      (5, false, false),
      (8, false, false),
      (1, true, false),
    ]) {
      final wire = _Wire();
      final bob = api.UserProfile(
        id: _bobProfile.id,
        username: _bobProfile.username,
        displayName: _bobProfile.displayName,
        createdAt: 0,
        topRolePosition: top,
        isOwner: owner,
      );
      await _pump(
        tester,
        wire,
        permissions: Perm.moveMembers,
        beside: _games,
        ladder: ladder,
        bob: bob,
      );
      await _dragBobOntoGames(tester);
      expect(
        wire.posts,
        hasLength(moved ? 1 : 0),
        reason: 'top $top, owner $owner',
      );
    }
  });

  testWidgets('a finger dragging a person moves nobody', (tester) async {
    final wire = _Wire();
    await _pump(
      tester,
      wire,
      permissions: Perm.moveMembers,
      beside: const RailMoveDropTarget(
        channelId: 'voice-2',
        child: SizedBox(width: 200, height: 60),
      ),
    );
    final target = tester.getCenter(find.byType(RailMoveDropTarget));
    final bob = tester.getCenter(find.text('Bob'));
    await tester.dragFrom(bob, target - bob);
    await tester.pumpAndSettle();
    expect(wire.posts, isEmpty);
  });

  testWidgets('you can drag yourself whatever your rank', (tester) async {
    final wire = _Wire();
    await _pump(
      tester,
      wire,
      permissions: Perm.moveMembers,
      beside: _games,
      ladder: const RoleLadder(permissions: Perm.moveMembers, topPosition: 1),
      bob: const api.UserProfile(
        id: 'user-bob',
        username: 'bob',
        displayName: 'Bob',
        createdAt: 0,
        topRolePosition: 1,
      ),
      me: const api.Me(
        id: 'user-bob',
        username: 'bob',
        displayName: 'Bob',
        createdAt: 0,
        permissions: Perm.moveMembers,
      ),
    );
    await _dragBobOntoGames(tester);
    expect(wire.posts, hasLength(1));
  });

  testWidgets('without the permission a person cannot be dragged', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, wire, permissions: 0, beside: _games);
    await _dragBobOntoGames(tester);
    expect(wire.posts, isEmpty);
  });

  test('the moved account follows into the new call and is told who', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    final session = FakeSession();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride((request) async {
          final body = {
            'url': 'wss://sfu.example.com',
            'room': 'r',
            'token': 'jwt',
            'expires_at': 0,
            'can_publish': true,
          };
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    container.read(voiceMoveFollowerProvider);
    final controller = container.read(voiceControllerProvider.notifier);
    await controller.join('voice-1');
    session.emitState(VoiceSessionState.connected);

    events.add(
      const api.VoiceMoved(
        fromChannelId: 'voice-1',
        toChannelId: 'voice-2',
        toChannelName: 'Games',
        movedById: 'u',
        movedByName: 'Alice',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(voiceControllerProvider).channelId, 'voice-2');
    expect(container.read(toastsProvider).map((t) => t.message), [
      'Alice moved you to Games.',
    ]);
  });

  test('a move out of a call this device is not in changes nothing', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride((_) async => http.Response('{}', 404)),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: FakeSession()),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    container.read(voiceMoveFollowerProvider);

    events.add(
      const api.VoiceMoved(
        fromChannelId: 'voice-1',
        toChannelId: 'voice-2',
        toChannelName: 'Games',
        movedById: 'u',
        movedByName: 'Alice',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(voiceControllerProvider).channelId, isNull);
    expect(container.read(toastsProvider), isEmpty);
  });
}
