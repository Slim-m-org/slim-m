// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What renders *inside* a presence tile - a live camera view or a screen
/// share; a participant with neither has no tile (decision 0086) - split out of
/// `canvas_presence_layer_test.dart` once this content pushed it past the
/// 500-line hard limit. That file covers layout and manipulation (drag,
/// resize, lock, hide, paint order); this one covers what gets painted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'features/canvas/presence_stack.dart';

const _onCamera = VoiceParticipant(
  identity: 'user-priya',
  name: 'Priya',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _cameraOff = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: true,
  isMuted: true,
  isLocal: false,
  isScreenSharing: false,
);

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

Widget _layer(
  CanvasDocument document,
  List<VoiceParticipant> participants,
  CanvasPresenceTileOverrides overrides, {
  required CameraViewBuilder cameraViewFor,
}) => PresenceStack(
  document: document,
  participants: participants,
  cameraViewFor: cameraViewFor,
  screenShareViewFor: (_) => const SizedBox(),
  overrides: overrides,
  onCommit: (_, __) {},
);

void main() {
  testWidgets('a camera-on participant renders the built camera view', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    var builtFor = <String>[];
    final overrides = CanvasPresenceTileOverrides();

    await tester.pumpWidget(
      _wrap(
        _layer(
          document,
          const [_onCamera],
          overrides,
          cameraViewFor: (identity) {
            builtFor.add(identity);
            return const ColoredBox(
              key: Key('live-camera'),
              color: Color(0xFF00FF00),
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(builtFor, ['user-priya']);
    expect(find.byKey(const Key('live-camera')), findsOneWidget);
  });

  testWidgets(
    'a camera-off participant never calls cameraViewFor and has no tile',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      var calls = 0;
      final overrides = CanvasPresenceTileOverrides();

      await tester.pumpWidget(
        _wrap(
          _layer(
            document,
            const [_cameraOff],
            overrides,
            cameraViewFor: (_) {
              calls++;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();

      expect(calls, 0);
      expect(find.byType(CanvasPresenceBubble), findsNothing);
      expect(find.byType(UserAvatar), findsNothing);
    },
  );

  testWidgets('the camera badge names the person and shows their mic state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const CanvasCameraBadge(participant: _onCamera)),
    );
    await tester.pump();

    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets(
    'a live camera bubble carries the float shadow and the window radius, '
    'the tokens reserved for an object that is always above the plane',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      final overrides = CanvasPresenceTileOverrides();

      await tester.pumpWidget(
        _wrap(
          _layer(
            document,
            const [_onCamera],
            overrides,
            cameraViewFor: (_) => const SizedBox(),
          ),
        ),
      );
      await tester.pump();

      final decorated = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(CanvasPresenceBubble),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .whereType<BoxDecoration>();
      expect(
        decorated.any((d) => d.boxShadow == AppShadows.canvasTile),
        isTrue,
        reason:
            'a live tile is never merely part of the plane, unlike an '
            'image or a stroke, so it carries the resting-tile lift '
            'unconditionally - lighter than float, which reads as a hard '
            'dark band under a permanent tile',
      );
      expect(
        decorated.any(
          (d) => d.borderRadius == BorderRadius.circular(AppRadii.window),
        ),
        isTrue,
      );
    },
  );
}
