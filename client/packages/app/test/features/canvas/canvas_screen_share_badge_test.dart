// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas screen-share tile's own name badge - reported directly by the
/// owner from two screenshots: the "Jellyfin's screen" chip sat permanently
/// over the video rather than appearing on hover, and a close crop showed
/// its box breaking the tile's own rounded bottom edge, overlapping the
/// canvas grid behind it.
///
/// This file drives real pointer events (`tester.createGesture(kind:
/// PointerDeviceKind.mouse)`), not a convenience tap helper, since the
/// behaviour under test is specifically what a hover-capable pointer does
/// that a tap cannot exercise - see `canvas_presence_tile_reveal_test.dart`'s
/// own library doc for the same discipline on this tile's other controls.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _jellyfin = VoiceParticipant(
  identity: 'user-jellyfin',
  name: 'Jellyfin',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
  isCameraOn: false,
);

Widget _wrapBubble(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: Center(child: SizedBox(width: 260, height: 160, child: child)),
    ),
  ),
);

double _badgeOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text("Jellyfin's screen"),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void main() {
  testWidgets(
    'with a mouse connected, the badge starts hidden and only shows while '
    'the tile is actually hovered',
    (tester) async {
      await tester.pumpWidget(
        _wrapBubble(
          const CanvasScreenShareBubble(
            participant: _jellyfin,
            view: ColoredBox(color: Color(0xFF123456)),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      // Registers a mouse without yet entering the tile - the badge must hide once a pointer exists, not wait for this tile.
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();

      expect(
        _badgeOpacity(tester),
        0,
        reason:
            'a mouse is connected and this tile is not hovered - the label '
            'must not sit permanently over the share',
      );

      await gesture.moveTo(
        tester.getCenter(find.byType(CanvasScreenShareBubble)),
      );
      await tester.pump(AppMotion.fast);

      expect(_badgeOpacity(tester), 1, reason: 'hovering reveals it');

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump(AppMotion.fast);

      expect(
        _badgeOpacity(tester),
        0,
        reason: 'the reveal must not outlive the hover that started it',
      );
    },
  );

  testWidgets(
    'with no mouse ever connected (touch), the badge stays on without any '
    'interaction - the information must not become unreachable on a phone',
    (tester) async {
      await tester.pumpWidget(
        _wrapBubble(
          const CanvasScreenShareBubble(
            participant: _jellyfin,
            view: ColoredBox(color: Color(0xFF123456)),
          ),
        ),
      );
      await tester.pump();

      expect(_badgeOpacity(tester), 1);
    },
  );

  testWidgets(
    'a non-interactive (sent-to-back) bubble keeps the badge on regardless '
    "of a connected mouse - it sits behind an IgnorePointer that a hover "
    'can never reach',
    (tester) async {
      await tester.pumpWidget(
        _wrapBubble(
          const CanvasScreenShareBubble(
            participant: _jellyfin,
            view: ColoredBox(color: Color(0xFF123456)),
            interactive: false,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();

      expect(_badgeOpacity(tester), 1);
    },
  );

  group('badge geometry stays inside the tile\'s own clip', () {
    Future<Rect> openBubble(
      WidgetTester tester, {
      required Rect worldRect,
    }) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      overrides.setRect('screen:user-jellyfin', worldRect);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: SizedBox(
                width: 1000,
                height: 800,
                child: CanvasPresenceLayer(
                  document: document,
                  participants: const [_jellyfin],
                  cameraViewFor: (_) => const SizedBox(),
                  screenShareViewFor: (_) =>
                      const ColoredBox(color: Color(0xFF123456)),
                  overrides: overrides,
                  onCommit: (_, __) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      return tester.getRect(
        find.ancestor(
          of: find.text("Jellyfin's screen"),
          matching: find.byType(ClipRRect),
        ),
      );
    }

    testWidgets('at the tile\'s default screen-share size', (tester) async {
      final clipRect = await openBubble(
        tester,
        worldRect: const Rect.fromLTWH(200, 100, 360, 203),
      );
      final badgeRect = tester.getRect(
        find
            .ancestor(
              of: find.text("Jellyfin's screen"),
              matching: find.byType(Container),
            )
            .first,
      );

      expect(badgeRect.top, greaterThanOrEqualTo(clipRect.top));
      expect(badgeRect.bottom, lessThanOrEqualTo(clipRect.bottom));
      expect(badgeRect.left, greaterThanOrEqualTo(clipRect.left));
    });

    testWidgets('after being resized down to the tile\'s minimum size', (
      tester,
    ) async {
      final clipRect = await openBubble(
        tester,
        worldRect: const Rect.fromLTWH(50, 50, 72, 54),
      );
      final badgeRect = tester.getRect(
        find
            .ancestor(
              of: find.text("Jellyfin's screen"),
              matching: find.byType(Container),
            )
            .first,
      );

      expect(
        badgeRect.top,
        greaterThanOrEqualTo(clipRect.top),
        reason:
            "the badge's own box must stay vertically inside the tile's "
            'clip even when the label text itself is wider than the tile, '
            'never breaking the bottom edge the way the report showed',
      );
      expect(badgeRect.bottom, lessThanOrEqualTo(clipRect.bottom));
    });
  });
}
