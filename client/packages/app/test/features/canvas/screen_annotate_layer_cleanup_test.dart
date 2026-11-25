// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The annotation layer stops animating once the last mark has faded, and a
/// cancelled sticky note does not leave its text behind.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/screen_annotate_layer.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

const _tile = Rect.fromLTWH(100, 100, 640, 360);

class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  var now = DateTime(2026, 10, 28, 12);
  late final feed = ScreenAnnotationFeed(
    selfId: () => 'me',
    callChannelId: () => 'call',
    callMembers: () => const ['me', 'sharer', 'viewer-2'],
    clock: () => now,
  );

  void handle(String userId, String kind, {String? text}) => feed.handle(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: userId,
      targetUserId: 'sharer',
      kind: kind,
      annotationId: 'm1',
      points: kind == 'consent' ? const [] : const [0.2, 0.2],
      color: 'annotation',
      text: text,
      ended: kind != 'consent',
      allowed: kind == 'consent',
      aspect: kind == 'consent' ? 16 / 9 : null,
    ),
  );

  Future<void> pump() async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenAnnotationFeedProvider.overrideWithValue(feed),
          voiceParticipantsProvider.overrideWithValue(const [_me]),
          voiceFlagsProvider.overrideWithValue(
            const VoiceFlags(channelId: 'call'),
          ),
          syncControllerProvider.overrideWith(NoopSyncController.new),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Stack(
              children: [
                ScreenAnnotateLayer(
                  sharerId: 'sharer',
                  sharerName: 'Ada',
                  tileRect: _tile,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('the ticker stops once the last mark has faded', (tester) async {
    final rig = _Rig(tester);
    await rig.pump();
    rig.handle('sharer', 'consent');
    rig.handle('viewer-2', 'note', text: 'hello');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'a mark is live');

    rig.now = rig.now.add(annotationNoteHold + annotationFade * 2);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('hello'), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a cancelled note does not come back on the next one', (
    tester,
  ) async {
    final rig = _Rig(tester);
    await rig.pump();
    rig.handle('sharer', 'consent');
    await tester.pump();

    await tester.tap(find.bySemanticsLabel("Put a note on Ada's screen"));
    await tester.pump();
    await tester.tapAt(_tile.topLeft + const Offset(320, 180));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'never sent');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tapAt(_tile.topLeft + const Offset(100, 100));
    await tester.pump();

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, isEmpty);
  });
}
