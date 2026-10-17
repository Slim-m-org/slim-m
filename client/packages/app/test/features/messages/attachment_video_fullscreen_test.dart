// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full screen route itself: opening it, and that swiping down actually
/// reaches [Navigator.pop] end to end. The drag-to-dismiss gesture's own
/// threshold/velocity/snap-back behaviour is covered in isolation by
/// `swipe_down_to_dismiss_test.dart` against a plain child, since mounting
/// a real `Video` widget repeatedly in one test process is slow and this
/// route only needs proving once that the two are wired together.
///
/// One real `Player` for the whole file, deliberately never disposed: once
/// a real `Video` widget has attached to it, `Player.dispose()` here hangs
/// waiting on a native texture teardown callback this headless test engine
/// never delivers. The test process exits and reclaims it either way, and
/// nothing later in the suite reuses this specific player.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_fullscreen.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness({required Player player, required bool touchGestures}) {
  final controller = VideoController(player);
  return AppTouchTargets(
    enabled: touchGestures,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showFullscreenAttachmentVideo(
                context,
                player: player,
                controller: controller,
                filename: 'clip.mp4',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _view() => find.byType(AttachmentVideoFullscreen);

void main() {
  late Player player;

  setUpAll(() {
    MediaKit.ensureInitialized();
    player = Player();
  });

  testWidgets('swiping down dismisses full screen when touch is on', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(player: player, touchGestures: true));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(_view(), findsOneWidget);

    await tester.drag(_view(), const Offset(0, 240));
    await tester.pumpAndSettle();

    expect(_view(), findsNothing);
  });

  testWidgets(
    'a wide window with no touch gestures keeps the drag inert, and the '
    'close button still dismisses',
    (tester) async {
      await tester.pumpWidget(_harness(player: player, touchGestures: false));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_view(), findsOneWidget);

      await tester.drag(_view(), const Offset(0, 240));
      await tester.pumpAndSettle();
      expect(_view(), findsOneWidget);

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is AppIconButton && w.semanticLabel == 'Close video',
        ),
      );
      await tester.pumpAndSettle();

      expect(_view(), findsNothing);
    },
  );
}
