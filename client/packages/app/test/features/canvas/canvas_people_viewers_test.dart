// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everyone with the board open is in the cluster and the people list, cursor or not, with follow only where it works.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_viewers.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_panel.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_people_cluster.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_people_session.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_blocks.dart';
import '../../support/fake_sync.dart';

const _board = 'board';

api.UserProfile _profile(String id, String name) =>
    api.UserProfile(id: id, username: id, displayName: name, createdAt: 0);

class _StaticProfiles extends StateNotifier<Map<String, api.UserProfile?>>
    implements BatchProfilesController {
  _StaticProfiles(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VoiceParticipant _call(String id, {bool local = false}) => VoiceParticipant(
  identity: id,
  name: id.toUpperCase(),
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

class _Rig {
  _Rig(
    this.tester, {
    this.call = const [],
    this.blocked = const {},
    this.roster = const ['ada', 'ben'],
  });

  final WidgetTester tester;
  final List<VoiceParticipant> call;
  final Set<String> blocked;
  final List<String> roster;
  final frames = StreamController<api.ServerEvent>.broadcast();
  final arrivals = <String>[];
  late final CanvasViewRelay relay;
  late final CanvasCursors cursors;
  late final ProviderContainer container;
  final log = CanvasActivityLog(isBlocked: (_) => false);

  void cursor(String id) =>
      cursors.upsert(id: id, x: 1, y: 0, label: id, colorIndex: 0);

  Future<void> pump({double width = 1000}) async {
    relay = CanvasViewRelay(
      board: const Rect.fromLTWH(0, 0, 1000, 1000),
      send: (_, {required summon, tile}) {},
      showView: (_) {},
      isBlocked: (_) => false,
      selfId: () => 'me',
    );
    cursors = CanvasCursors();
    addTearDown(relay.dispose);
    addTearDown(cursors.dispose);
    addTearDown(frames.close);
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final names = {
      for (final id in ['me', 'ada', 'ben', 'cy'])
        id: _profile(id, id[0].toUpperCase() + id.substring(1)),
    };
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        liveEventsProvider.overrideWithValue(frames.stream),
        syncControllerProvider.overrideWith((ref) => StubSyncController(ref)),
        serverInfoProvider.overrideWith(
          (ref) async => api.Version.fromJson({
            'name': 'slim-m',
            'version': '0.138.0',
            'protocol': 1,
            'capabilities': ['canvas_viewers'],
          }),
        ),
        batchProfilesControllerProvider.overrideWith(
          (ref) => _StaticProfiles(names),
        ),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(ref, BlocksState(ids: blocked)),
        ),
        voiceParticipantsProvider.overrideWithValue(call),
        voiceFlagsProvider.overrideWithValue(
          VoiceFlags(channelId: call.isEmpty ? null : _board),
        ),
        mockApiOverride(
          (request) async => http.Response(
            jsonEncode({
              'channels': [
                if (roster.isNotEmpty)
                  {
                    'channel_id': _board,
                    'viewers': [
                      for (var i = 0; i < roster.length; i++)
                        {'user_id': roster[i], 'since': 10 + i},
                    ],
                  },
              ],
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(serverInfoProvider, (_, _) {});
    container.listen(canvasViewerArrivalProvider, (_, next) {
      if (next != null) arrivals.add(next.userId);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: CanvasPeopleHost(
                    channelId: _board,
                    relay: relay,
                    cursors: cursors,
                    selfId: 'me',
                    viewMode: null,
                    onBringEveryone: () {},
                    child: const Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CanvasPeopleCluster(),
                      ),
                    ),
                  ),
                ),
                CanvasActivityAnnouncer(activityLog: log),
              ],
            ),
          ),
        ),
      ),
    );
    await waitUntil(tester, () => container.read(canvasViewersProvider).loaded);
  }

  Future<void> openList() async {
    await tester.tap(find.byTooltip('People here'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> frame(String user, bool viewing) async {
    frames.add(
      api.CanvasViewerChanged(
        channelId: _board,
        userId: user,
        viewing: viewing,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  String get liveRegion => tester
      .getSemantics(find.byKey(CanvasActivityAnnouncer.liveRegionKey))
      .label;
}

Finder _row(String name) => find
    .ancestor(
      of: find.text(name),
      matching: find.byWidgetPredicate((w) => w is AppListRow),
    )
    .first;

void main() {
  testWidgets('an idle viewer with no cursor is in the cluster and the list', (
    tester,
  ) async {
    final rig = _Rig(tester);
    await rig.pump();

    expect(find.byTooltip('People here'), findsOneWidget);
    await rig.openList();

    final ada = tester.getRect(_row('Ada'));
    final ben = tester.getRect(_row('Ben'));
    expect(ada.width, ben.width);
    expect(ada.left, ben.left);
    expect(ben.top, greaterThanOrEqualTo(ada.bottom));
    expect(find.byTooltip('Follow Ada'), findsNothing);
    expect(find.byTooltip('Follow Ben'), findsNothing);
  });

  testWidgets('this device alone has nobody to list', (tester) async {
    final rig = _Rig(tester, roster: const ['me']);
    await rig.pump();

    expect(find.byTooltip('People here'), findsNothing);
  });

  testWidgets('the call comes first, then viewers by arrival, each once', (
    tester,
  ) async {
    final rig = _Rig(
      tester,
      call: [_call('me', local: true), _call('ben')],
      roster: const ['ada', 'ben', 'cy'],
    );
    await rig.pump();
    await rig.openList();

    final tops = [
      for (final name in ['ME', 'BEN', 'Ada', 'Cy'])
        tester.getRect(_row(name)).top,
    ];
    expect(tops, [...tops]..sort());
    expect(find.text('Ben'), findsNothing, reason: 'listed once, as the call');
  });

  testWidgets(
    'follow is offered to the call and to a cursor, not to a viewer',
    (tester) async {
      final rig = _Rig(
        tester,
        call: [_call('me', local: true), _call('cy')],
        roster: const ['ada', 'ben'],
      );
      await rig.pump();
      rig.cursor('ben');
      await tester.pump();
      await rig.openList();

      expect(find.byTooltip('Follow CY'), findsOneWidget);
      expect(find.byTooltip('Follow Ben'), findsOneWidget);
      expect(find.byTooltip('Follow Ada'), findsNothing);
    },
  );

  testWidgets('a viewer this device blocks is not listed', (tester) async {
    final rig = _Rig(tester, blocked: const {'ben'});
    await rig.pump();
    await rig.openList();

    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Ben'), findsNothing);
  });

  testWidgets(
    'one polite line per arrival, and none for who was already here',
    (tester) async {
      final handle = tester.ensureSemantics();
      final rig = _Rig(tester);
      await rig.pump();
      expect(rig.liveRegion, isEmpty);
      expect(rig.arrivals, isEmpty);

      await rig.frame('cy', true);
      await tester.pump();
      expect(rig.liveRegion, 'Cy opened the canvas');
      expect(rig.arrivals, ['cy']);

      await rig.frame('me', true);
      await rig.frame('cy', false);
      await rig.frame('cy', true);
      await tester.pump();
      expect(rig.arrivals, ['cy', 'cy'], reason: 'self never, a return yes');
      handle.dispose();
    },
  );
}
