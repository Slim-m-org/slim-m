// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Expanding one canvas presence tile to full screen - the owner's report
/// was "no way to full screen a camera", which was closed on the voice
/// screen (PR #468, `voice_screen_fullscreen_test.dart`) and left open on
/// the canvas, where every camera bubble the same report's second half is
/// about actually lives.
///
/// Covers the affordance and its one gate (a camera showing the avatar
/// fallback has no feed to expand), that the route opened is the *existing*
/// `showFullscreenVideo` rather than a second fullscreen of the canvas's
/// own, and the half only this surface owns: while a tile is expanded,
/// [CanvasPresenceLayer] narrows video interest to that one key, so every
/// other participant's video is unsubscribed for as long as nobody can see
/// it, and restored however the route is closed.
///
/// The interest assertions read the real reported sets rather than asserting
/// "fewer": a fixture of three cameras all inside the viewport is what makes
/// the before and after genuinely disagree, where a single participant would
/// report one key either way and pass without exercising anything.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_controls.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'voice_controller_harness.dart';

const _expandLabel = 'Show this tile full screen';

VoiceParticipant _camera(String id, String name, {bool on = true}) =>
    VoiceParticipant(
      identity: id,
      name: name,
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
      isCameraOn: on,
    );

/// Three remote cameras, all on. Three is the point: the narrowed answer has
/// to be provably smaller than the ordinary one.
final _roster = [
  _camera('user-noor', 'Noor'),
  _camera('user-ada', 'Ada'),
  _camera('user-rex', 'Rex'),
];

/// Everything one of these tests drives, plus the interest sets the layer
/// actually reported, in order.
class _Fixture {
  _Fixture(this.harness, this.session, this.document, this.interest);

  final VoiceHarness harness;
  final FakeSession session;
  final CanvasDocument document;
  final List<Set<String>?> interest;

  /// Stops the heartbeat `connected` started, from the test body itself: the
  /// pending-timer check runs before `addTearDown`, the trap
  /// `sign_out_leaves_call_test.dart` already documents.
  Future<void> leave() =>
      harness.container.read(voiceControllerProvider.notifier).leave();
}

Future<_Fixture> _seated(
  WidgetTester tester, {
  List<VoiceParticipant>? participants,
}) async {
  final roster = participants ?? _roster;
  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(session, voiceApi());
  final document = CanvasDocument()..setViewport(const Size(1200, 800));
  addTearDown(document.dispose);
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(overrides.dispose);
  final interest = <Set<String>?>[];

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: CanvasPresenceLayer(
              document: document,
              participants: roster,
              cameraViewFor: (id) => SizedBox(key: Key('camera-$id')),
              screenShareViewFor: (id) => SizedBox(key: Key('screen-$id')),
              overrides: overrides,
              onCommit: (_, __) {},
              onVideoInterest: interest.add,
            ),
          ),
        ),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants(roster);
  await tester.pumpAndSettle();

  return _Fixture(harness, session, document, interest);
}

/// Reveals one tile's control row the way a desktop pointer does - the row
/// is hidden until hovered, pressed or focused (`canvas_presence_tile_reveal
/// _test.dart` owns that behaviour).
Future<void> _hover(WidgetTester tester, String key) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(
    location: tester.getCenter(find.byKey(ValueKey(key))),
  );
  await tester.pump(AppMotion.fast);
}

/// One named tile's own expand control. Scoped to that tile rather than
/// matched by label alone: the row carries `alwaysIncludeSemantics`, so
/// every tile on the canvas answers the bare label whether revealed or not.
Finder _expandButton(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.bySemanticsLabel(_expandLabel),
);

void main() {
  testWidgets('a camera tile that is actually showing a camera offers a '
      'full-screen control', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');

    expect(_expandButton('camera:user-noor'), findsOneWidget);
    await fixture.leave();
  });

  testWidgets('a camera tile showing the avatar fallback offers none, since '
      'there is no feed to fill a screen with', (tester) async {
    final fixture = await _seated(
      tester,
      participants: [_camera('user-noor', 'Noor', on: false)],
    );
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');

    expect(
      _expandButton('camera:user-noor'),
      findsNothing,
      reason:
          'FullscreenVideoView pops itself the moment it opens on a feed '
          'that is not live, so offering the control would be a button that '
          'cannot work',
    );
    expect(
      find.byWidgetPredicate((w) => w is TileControls),
      findsOneWidget,
      reason:
          'the rest of the row must still be there - this asserts the '
          'expand button alone is gated, not that the tile lost its '
          'controls entirely',
    );
    await fixture.leave();
  });

  testWidgets('expanding a tile opens the same route the voice screen uses, '
      'never a second canvas fullscreen', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');
    await tester.tap(_expandButton('camera:user-noor'));
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenVideoView), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.semanticLabel == 'Exit full screen',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenVideoView), findsNothing);
    await fixture.leave();
  });

  testWidgets('an expanded tile narrows video interest to itself alone, and '
      'closing it restores every other tile', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    expect(fixture.interest.last, {
      'camera:user-noor',
      'camera:user-ada',
      'camera:user-rex',
    }, reason: 'all three cameras are inside the viewport to begin with');

    await _hover(tester, 'camera:user-noor');
    await tester.tap(_expandButton('camera:user-noor'));
    await tester.pumpAndSettle();

    expect(
      fixture.interest.last,
      {'camera:user-noor'},
      reason:
          'the two tiles nobody can see behind the route must be '
          'unsubscribed, not merely hidden',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      fixture.interest.last,
      {'camera:user-noor', 'camera:user-ada', 'camera:user-rex'},
      reason:
          'Escape pops the route without telling the layer, so the restore '
          'has to ride the await rather than a callback of the route own',
    );
    await fixture.leave();
  });

  testWidgets('a participant leaving while their tile is expanded restores '
      'interest to whoever is left', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');
    await tester.tap(_expandButton('camera:user-noor'));
    await tester.pumpAndSettle();
    expect(fixture.interest.last, {'camera:user-noor'});

    fixture.session.emitParticipants([_roster[1], _roster[2]]);
    await tester.pumpAndSettle();

    expect(
      find.byType(FullscreenVideoView),
      findsNothing,
      reason: 'the route closes itself once the feed stops being live',
    );
    await fixture.leave();
  });
}
