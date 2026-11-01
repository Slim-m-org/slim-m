// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The choice and the explanation a viewer sees under the position bar, and the
/// player in the stage slot. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/direct_play_controller.dart';
import 'package:slimm_app/src/features/voice/providers/direct_play_provider.dart';
import 'package:slimm_app/src/features/voice/providers/watch_room.dart';
import 'package:slimm_app/src/features/voice/widgets/direct_play_panel.dart';
import 'package:slimm_app/src/features/voice/widgets/direct_play_stage.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';
import 'direct_play_fakes.dart';

const _channel = 'call-1';
const _stageKey = Key('direct-stage');
const _panelKey = Key('direct-panel');

Future<DirectPlayController> _scene(
  WidgetTester tester,
  Rig rig, {
  required double width,
  required Brightness brightness,
  api.WatchDirectPlay? offer = const api.WatchDirectPlay(
    baseUrl: jellyUrl,
    verifiedUserIds: ['me'],
  ),
  Future<void> Function(DirectPlayController c)? arrange,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = DirectPlayController(rig.env(), _channel);
  final current = room(rig, offer: offer, positionMs: 4983000);
  await c.onRoom(current);
  if (arrange != null) await arrange(c);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        watchRoomProvider.overrideWith((ref, id) => Stream.value(current)),
        directPlayControllerProvider.overrideWith((ref, id) {
          ref.onDispose(c.dispose);
          return c;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(
          brightness,
          brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
        ),
        home: Scaffold(
          backgroundColor:
              (brightness == Brightness.dark ? AppTokens.dark : AppTokens.light)
                  .surfaceBase,
          body: RepaintBoundary(
            key: snapshotBoundary,
            child: ColoredBox(
              color:
                  (brightness == Brightness.dark
                          ? AppTokens.dark
                          : AppTokens.light)
                      .surfaceBase,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DirectPlayPanel(key: _panelKey, channelId: _channel),
                    const SizedBox(height: AppSpacing.s12),
                    if (c.current.active)
                      const Flexible(
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: DirectPlayStage(
                            key: _stageKey,
                            channelId: _channel,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return c;
}

void main() {
  setUpAll(loadRealFonts);

  for (final width in const [390.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      final label = '${width.toInt()}-${brightness.name}';

      testWidgets(
        'offers the choice with the row a touch target tall ($label)',
        (tester) async {
          await _scene(tester, Rig(), width: width, brightness: brightness);
          expect(find.text('Watch at source quality'), findsOneWidget);
          final row = tester.getSize(find.byKey(_panelKey));
          expect(row.height, greaterThanOrEqualTo(AppSizes.rowTouch));
          expect(row.width, width - 2 * AppSpacing.s16);
          await writeSnapshot(tester, 'direct-play-offer-$label');
        },
      );

      testWidgets('names the failed test in one line that fits ($label)', (
        tester,
      ) async {
        await _scene(
          tester,
          Rig(),
          width: width,
          brightness: brightness,
          offer: const api.WatchDirectPlay(baseUrl: jellyUrl),
        );
        expect(
          find.text(
            'Watching the shared stream. Link a Jellyfin account to watch at source quality.',
          ),
          findsOneWidget,
        );
        expect(find.text('Watch at source quality'), findsNothing);
        await writeSnapshot(tester, 'direct-play-blocked-$label');
      });

      testWidgets(
        'plays in the stage slot and a local pause says where the room is ($label)',
        (tester) async {
          final c = await _scene(
            tester,
            Rig(),
            width: width,
            brightness: brightness,
            arrange: (c) async {
              await c.enable();
              await c.pauseLocally();
            },
          );
          await tester.pump();
          expect(c.current.phase, DirectPlayPhase.playing);
          expect(
            find.text('You are paused, the room is at 1:23:03'),
            findsOneWidget,
          );
          expect(find.text('Rejoin the room'), findsOneWidget);
          final stage = tester.getRect(find.byKey(_stageKey));
          expect(stage.width / stage.height, closeTo(16 / 9, 0.05));
          final band = tester.getRect(find.text('Rejoin the room'));
          expect(stage.contains(band.center), isTrue);
          await writeSnapshot(tester, 'direct-play-paused-$label');
        },
      );
    }
  }

  testWidgets('a fall back offers a way back, in the panel', (tester) async {
    final rig = Rig()..openError = StateError('no codec');
    await _scene(
      tester,
      rig,
      width: 390,
      brightness: Brightness.light,
      arrange: (c) => c.enable(),
    );
    expect(
      find.text('Could not play from Jellyfin. Back on the shared stream.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });
}
