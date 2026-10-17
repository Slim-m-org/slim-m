// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Temporary voice rooms from the client (decision 0065): opening a lobby
/// moves you into your own room, its settings save, the owner's sheet saves,
/// and a voice row says when it is a lobby, locked, or capped.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_app/src/features/voice/screens/voice_lobby_redirect.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_room_glyphs.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_room_settings_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/channels/channel_management_harness.dart';
import 'voice_controller_harness.dart';

const _json = {'content-type': 'application/json'};

Map<String, Object?> _roomJson({bool locked = false, int limit = 0}) => {
  'id': 'room-1',
  'name': "User's room",
  'kind': 'voice',
  'created_at': 0,
  'room_owner_id': 'user-1',
  'room_locked': locked,
  'user_limit': limit,
};

Channel _voiceRow({
  bool? createsRooms,
  String? roomOwnerId,
  bool? roomLocked,
  int? userLimit,
}) => Channel(
  id: 'v1',
  name: 'hangout',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  createsRooms: createsRooms,
  roomOwnerId: roomOwnerId,
  roomLocked: roomLocked,
  userLimit: userLimit,
);

Future<void> _pumpRow(WidgetTester tester, Channel channel) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, const VoiceState()),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: VoiceChannelRow(channel: channel, selected: false),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('opening a lobby moves you into your own room', (tester) async {
    final requests = <String>[];
    await tester.pumpWidget(
      harness(
        const VoiceLobbyRedirect(lobbyId: 'lobby'),
        handler: (request) {
          requests.add('${request.method} ${request.url.path}');
          return http.Response(jsonEncode(_roomJson()), 200, headers: _json);
        },
      ),
    );
    // The connecting halo animates forever, so frames are pumped, not settled.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(requests, contains('POST /channels/lobby/voice/room'));
    expect(find.text('channel:room-1'), findsOneWidget);
  });

  testWidgets('a lobby that cannot make a room says so and can retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      harness(
        const VoiceLobbyRedirect(lobbyId: 'lobby'),
        handler: (request) {
          if (request.url.path == '/channels/lobby/voice/room') calls++;
          return http.Response(
            jsonEncode({'error': 'this channel does not make rooms'}),
            400,
            headers: _json,
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('channel:'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('a voice channel can make a room per person and take a limit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bodies = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      harness(
        SingleChildScrollView(
          child: ChannelSettingsPane(
            channel: channel('c1', 'hangout', kind: 'voice'),
            wasOpen: false,
          ),
        ),
        handler: (request) {
          if (request.method == 'PATCH') {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'id': 'c1',
                'name': 'hangout',
                'kind': 'voice',
                'created_at': 0,
                ...bodies.last,
              }),
              200,
              headers: _json,
            );
          }
          return http.Response('{"participants": []}', 200, headers: _json);
        },
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle &&
          w.semanticLabel == 'Joining makes each person a room of their own',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(bodies.single, {'creates_rooms': true});

    await tester.ensureVisible(find.text('User limit'));
    await tester.tap(find.text('User limit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5').last);
    await tester.pumpAndSettle();
    expect(bodies.last, {'user_limit': 5});
  });

  testWidgets('a room hides "Room per person": a room never makes rooms', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final room = _voiceRow(roomOwnerId: 'user-1');
    await tester.pumpWidget(
      harness(
        SingleChildScrollView(
          child: ChannelSettingsPane(channel: room, wasOpen: false),
        ),
        handler: (_) =>
            http.Response('{"participants": []}', 200, headers: _json),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Room per person'), findsNothing);
    expect(find.text('User limit'), findsOneWidget);
  });

  testWidgets("the owner's sheet locks the room", (tester) async {
    final bodies = <String, Map<String, dynamic>>{};
    final room = _voiceRow(roomOwnerId: 'user-1', roomLocked: false);
    await tester.pumpWidget(
      harness(
        VoiceRoomSettingsSheet(room: room),
        handler: (request) {
          bodies['${request.method} ${request.url.path}'] =
              jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_roomJson(locked: true)),
            200,
            headers: _json,
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppToggle && w.semanticLabel == 'Lock the room',
      ),
    );
    await tester.pumpAndSettle();
    expect(bodies['PATCH /channels/v1/room'], {'locked': true});
  });

  test('only the owner or a channel manager may edit a room', () {
    final room = _voiceRow(roomOwnerId: 'user-1');
    expect(canEditRoom(room, 'user-1', canManage: false), isTrue);
    expect(canEditRoom(room, 'user-2', canManage: false), isFalse);
    expect(canEditRoom(room, 'user-2', canManage: true), isTrue);
    expect(
      canEditRoom(_voiceRow(), 'user-1', canManage: true),
      isFalse,
      reason: 'an ordinary channel has no room settings',
    );
  });

  testWidgets('a lobby row shows its own icon instead of the voice glyph', (
    tester,
  ) async {
    await _pumpRow(tester, _voiceRow(createsRooms: true));
    expect(find.byType(RailLobbyIcon), findsOneWidget);
    expect(find.byIcon(AppIcons.voice), findsNothing);
    expect(find.byTooltip(RailLobbyIcon.label), findsOneWidget);
  });

  testWidgets('a locked, capped room says so on its row', (tester) async {
    await _pumpRow(
      tester,
      _voiceRow(roomOwnerId: 'user-1', roomLocked: true, userLimit: 5),
    );
    expect(find.byTooltip(RailRoomLockedGlyph.label), findsOneWidget);
    expect(find.text('0/5'), findsOneWidget);
    final row = tester.getRect(find.byType(AppListRow));
    expect(
      tester.getRect(find.text('0/5')).right,
      lessThanOrEqualTo(row.right),
    );
  });
}
