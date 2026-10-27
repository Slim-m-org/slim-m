// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The follow panel: stopping a follow that outlived its person, asking before
/// a summon, hiding the summon from the personal view, and not rebuilding for
/// cursor frames that change nobody on the list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_follow_controls.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _Rig {
  _Rig(this.tester, {this.canBring = true}) {
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
  final bool canBring;
  late final CanvasViewRelay relay;
  late final CanvasCursors cursors;
  int brought = 0;

  void cursor(String id, double x) =>
      cursors.upsert(id: id, x: x, y: 0, label: id, colorIndex: 0);

  Future<void> pump() async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Stack(
              children: [
                CanvasFollowControls(
                  relay: relay,
                  cursors: cursors,
                  participants: const [],
                  selfId: 'me',
                  canBringEveryone: canBring,
                  onBringEveryone: () => brought++,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('Stop shows while following, and a leaver is un-followed', (
    tester,
  ) async {
    final rig = _Rig(tester)..cursor('amy', 1);
    await rig.pump();
    rig.relay.follow('amy');
    await tester.pump();

    expect(find.byTooltip('Stop following amy'), findsWidgets);

    rig.cursors.remove('amy');
    await tester.pump();
    await tester.pump();

    expect(rig.relay.following.value, isNull);
    expect(find.byType(Tooltip), findsNothing, reason: 'nothing left to show');
  });

  testWidgets('Bring everyone to me asks first', (tester) async {
    final rig = _Rig(tester)..cursor('amy', 1);
    await rig.pump();

    await tester.tap(find.byTooltip('Bring everyone to me'));
    await tester.pumpAndSettle();
    expect(find.text('Bring everyone to you?'), findsOneWidget);
    expect(rig.brought, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(rig.brought, 0);

    await tester.tap(find.byTooltip('Bring everyone to me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bring everyone'));
    await tester.pumpAndSettle();
    expect(rig.brought, 1);
  });

  testWidgets('the personal view is not offered a summon', (tester) async {
    final rig = _Rig(tester, canBring: false)..cursor('amy', 1);
    await rig.pump();

    expect(find.byTooltip('Bring everyone to me'), findsNothing);
    expect(find.byTooltip('Follow amy'), findsOneWidget);
  });

  testWidgets('a cursor that only moves does not rebuild the people', (
    tester,
  ) async {
    final rig = _Rig(tester)
      ..cursor('amy', 1)
      ..cursor('bo', 1);
    await rig.pump();

    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget.runtimeType.toString() == '_PersonButton') rebuilt++;
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
}
