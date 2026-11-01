// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one people panel (decision 0095): follow a person from the list, see the follow as an outline and a chip, ask before a summon, let go of someone who left, and not rebuild for a cursor that only moved.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_follow_status.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_people_cluster.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_people_panel.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_people_session.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

VoiceParticipant _call(String id, {bool local = false}) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

class _Rig {
  _Rig(this.tester, {this.call = const []}) {
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
  }

  final WidgetTester tester;
  final List<VoiceParticipant> call;
  late final CanvasViewRelay relay;
  late final CanvasCursors cursors;
  int brought = 0;

  void cursor(String id, double x) =>
      cursors.upsert(id: id, x: x, y: 0, label: id, colorIndex: 0);

  Future<void> pump({double width = 1000}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [voiceParticipantsProvider.overrideWithValue(call)],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: CanvasPeopleHost(
              relay: relay,
              cursors: cursors,
              selfId: 'me',
              viewMode: null,
              onBringEveryone: () => brought++,
              child: Stack(
                children: [
                  CanvasFollowStatus(
                    participants: call,
                    below: const SizedBox.shrink(),
                  ),
                  const Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CanvasPeopleCluster(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openList() async {
    await tester.tap(find.byTooltip('People here'));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('following from the list outlines the view and names them', (
    tester,
  ) async {
    final rig = _Rig(tester)..cursor('amy', 1);
    await rig.pump();
    await rig.openList();

    await tester.tap(find.byTooltip('Follow amy'));
    await tester.pump();

    expect(rig.relay.following.value, 'amy');
    expect(find.byKey(followOutlineKey), findsOneWidget);
    expect(find.text('Following amy'), findsOneWidget);
    expect(find.byKey(followRingKey), findsWidgets);
    expect(find.byTooltip('Stop following amy'), findsWidgets);
  });

  testWidgets('the chip stops the follow and the outline goes with it', (
    tester,
  ) async {
    final rig = _Rig(tester)..cursor('amy', 1);
    await rig.pump();
    rig.relay.follow('amy');
    await tester.pump();

    await tester.tap(find.text('Following amy'));
    await tester.pump();

    expect(rig.relay.following.value, isNull);
    expect(find.byKey(followOutlineKey), findsNothing);
  });

  testWidgets('someone with no cursor is followed from the call list', (
    tester,
  ) async {
    final rig = _Rig(tester, call: [_call('me', local: true), _call('bo')]);
    await rig.pump();
    await rig.openList();

    await tester.tap(find.byTooltip('Follow bo'));
    await tester.pump();

    expect(rig.relay.following.value, 'bo');
  });

  testWidgets('a followed person who leaves is let go', (tester) async {
    final rig = _Rig(tester)..cursor('amy', 1);
    await rig.pump();
    rig.relay.follow('amy');
    await tester.pump();

    rig.cursors.remove('amy');
    await tester.pump();
    await tester.pump();

    expect(rig.relay.following.value, isNull);
    expect(find.byKey(followOutlineKey), findsNothing);
  });

  testWidgets('Bring everyone to me asks first', (tester) async {
    final rig = _Rig(tester)..cursor('amy', 1);
    await rig.pump();
    await rig.openList();

    await tester.tap(find.text('Bring everyone to me'));
    await tester.pumpAndSettle();
    expect(find.text('Bring everyone to you?'), findsOneWidget);
    expect(rig.brought, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(rig.brought, 0);

    await tester.tap(find.text('Bring everyone to me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bring everyone'));
    await tester.pumpAndSettle();
    expect(rig.brought, 1);
  });

  testWidgets('a cursor that only moves does not rebuild the people', (
    tester,
  ) async {
    final rig = _Rig(tester)
      ..cursor('amy', 1)
      ..cursor('bo', 1);
    await rig.pump();
    await rig.openList();

    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is CanvasPersonRow) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    for (var i = 0; i < 20; i++) {
      rig.cursor('amy', 10.0 * i);
      await tester.pump();
    }
    expect(rebuilt, 0);

    rig.cursor('cy', 1);
    await tester.pump();
    expect(rebuilt, greaterThan(0), reason: 'a new person does rebuild it');
  });

  testWidgets('12 others on a phone keep Bring everyone to me reachable', (
    tester,
  ) async {
    final rig = _Rig(
      tester,
      call: [
        _call('me', local: true),
        for (var i = 0; i < 12; i++) _call('user-$i'),
      ],
    );
    await rig.pump(width: 390);
    await rig.openList();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'RenderFlex overflow');
    final bring = find.text('Bring everyone to me');
    await tester.ensureVisible(bring);
    await tester.pump();
    expect(tester.getRect(bring).right, lessThanOrEqualTo(390));
    expect(tester.getRect(bring).bottom, lessThanOrEqualTo(800));
  });
}
