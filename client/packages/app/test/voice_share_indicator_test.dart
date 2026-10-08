// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the local screen-share indicator: the in-call banner and the
/// collapsed strip both have to show a live share, and both have to stay
/// quiet for a share that is only requested, never actually live.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_app/src/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  group('the in-call banner', () {
    // Decision 0047, point 8: no banner for a live share; the share control says it instead.
    testWidgets('a live share has no banner, and the share control says so', (
      tester,
    ) async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
      );
      await tester.pump();
      await controller.setScreenShare(true);
      await tester.pump();

      expect(find.byType(AppCallout), findsNothing);
      expect(
        find.byTooltip(RegExp(r'^You are sharing your screen\. Stop sharing')),
        findsOneWidget,
      );
      // Clears the heartbeat timer a connected call now keeps running.
      await controller.leave();
    });

    /// canvas.md/voice.md: a real system picker the caller has to go
    /// answer, with nothing on screen saying so beyond a bare spinner in
    /// the control row and a hover/long-press tooltip.
    testWidgets(
      'stays quiet on the active-share banner for a share only requested, '
      'not live, and shows the pending one instead',
      (tester) async {
        final session = FakeSession(
          screenShareOutcome: ScreenShareOutcome.pendingBroadcast,
        );
        final controller = harness.controllerWith(session, voiceApi());
        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);

        await tester.pumpWidget(
          _harness(
            const VoiceScreen(channelId: 'channel-1'),
            harness.container,
          ),
        );
        await tester.pump();
        await controller.setScreenShare(true);
        await tester.pump();

        expect(controller.state.awaitingBroadcast, isTrue);
        expect(find.text('You are sharing your screen.'), findsNothing);
        expect(
          find.textContaining('Waiting for you to start the broadcast'),
          findsOneWidget,
        );

        // Clears the pending-broadcast deadline and heartbeat timers.
        await controller.leave();
      },
    );

    testWidgets('stays quiet with no share at all', (tester) async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
      );
      await tester.pump();

      expect(find.text('You are sharing your screen.'), findsNothing);
      await controller.leave();
    });
  });

  group('the share stage', () {
    testWidgets('renders a remote share, named for its sharer', (tester) async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
      );
      await tester.pump();
      session.emitParticipants(const [
        VoiceParticipant(
          identity: 'me',
          name: 'Me',
          isSpeaking: false,
          isMuted: false,
          isLocal: true,
          isScreenSharing: false,
        ),
        VoiceParticipant(
          identity: 'peer-1',
          name: 'Ada',
          isSpeaking: false,
          isMuted: false,
          isLocal: false,
          isScreenSharing: true,
        ),
      ]);
      await tester.pump();

      // The stage mounted, wired to the sharing participant specifically.
      expect(find.byKey(const Key('fake-share-view-peer-1')), findsOneWidget);
      expect(find.text("Ada's screen"), findsOneWidget);
      await controller.leave();
    });

    testWidgets(
      'your own share gets the stage, without the banner stacked on top of '
      'it',
      (tester) async {
        final session = FakeSession();
        final controller = harness.controllerWith(session, voiceApi());
        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);

        await tester.pumpWidget(
          _harness(
            const VoiceScreen(channelId: 'channel-1'),
            harness.container,
          ),
        );
        await tester.pump();
        session.emitParticipants(const [
          VoiceParticipant(
            identity: 'me',
            name: 'Me',
            isSpeaking: false,
            isMuted: false,
            isLocal: true,
            isScreenSharing: true,
          ),
        ]);
        await tester.pump();

        // The stage's own caption already says you are sharing; the
        // banner would only repeat it.
        expect(find.text('You are sharing your screen.'), findsNothing);
        expect(find.byKey(const Key('fake-share-view-me')), findsOneWidget);
        expect(find.text('You are sharing your screen'), findsOneWidget);
        await controller.leave();
      },
    );

    testWidgets(
      'before the roster has anyone to put on stage, the share control '
      'says you are sharing, with no banner '
      'put on stage',
      (tester) async {
        final session = FakeSession();
        final controller = harness.controllerWith(session, voiceApi());
        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);

        await tester.pumpWidget(
          _harness(
            const VoiceScreen(channelId: 'channel-1'),
            harness.container,
          ),
        );
        await tester.pump();
        await controller.setScreenShare(true);
        await tester.pump();

        expect(find.text('You are sharing your screen.'), findsNothing);
        expect(
          find.byTooltip(
            RegExp(r'^You are sharing your screen\. Stop sharing'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('fake-share-view-me')), findsNothing);
        await controller.leave();
      },
    );

    testWidgets(
      'a remote sharer taking the stage over you leaves no banner, and the '
      'share control still says you are sharing; '
      "the stage's caption is naming someone else",
      (tester) async {
        final session = FakeSession();
        final controller = harness.controllerWith(session, voiceApi());
        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);

        await tester.pumpWidget(
          _harness(
            const VoiceScreen(channelId: 'channel-1'),
            harness.container,
          ),
        );
        await tester.pump();
        session.emitParticipants(const [
          VoiceParticipant(
            identity: 'me',
            name: 'Me',
            isSpeaking: false,
            isMuted: false,
            isLocal: true,
            isScreenSharing: true,
          ),
          VoiceParticipant(
            identity: 'peer-1',
            name: 'Ada',
            isSpeaking: false,
            isMuted: false,
            isLocal: false,
            isScreenSharing: true,
          ),
        ]);
        await tester.pump();

        expect(find.text("Ada's screen"), findsOneWidget);
        expect(find.text('You are sharing your screen.'), findsNothing);
        expect(
          find.byTooltip(
            RegExp(r'^You are sharing your screen\. Stop sharing'),
          ),
          findsOneWidget,
        );
        await controller.leave();
      },
    );
  });

  group('the camera self preview', () {
    testWidgets('shows nothing when the camera is off', (tester) async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
      );
      await tester.pump();
      session.emitParticipants(const [
        VoiceParticipant(
          identity: 'me',
          name: 'Me',
          isSpeaking: false,
          isMuted: false,
          isLocal: true,
          isScreenSharing: false,
        ),
      ]);
      await tester.pump();

      expect(find.byKey(const Key('fake-camera-view-me')), findsNothing);
      await controller.leave();
    });

    testWidgets(
      'shows your own camera alone in the call, the exact gap reported',
      (tester) async {
        final session = FakeSession();
        final controller = harness.controllerWith(session, voiceApi());
        await controller.join('channel-1');
        session.emitState(VoiceSessionState.connected);

        await tester.pumpWidget(
          _harness(
            const VoiceScreen(channelId: 'channel-1'),
            harness.container,
          ),
        );
        await tester.pump();
        session.emitParticipants(const [
          VoiceParticipant(
            identity: 'me',
            name: 'Me',
            isSpeaking: false,
            isMuted: false,
            isLocal: true,
            isScreenSharing: false,
            isCameraOn: true,
          ),
        ]);
        await tester.pump();

        expect(find.byKey(const Key('fake-camera-view-me')), findsOneWidget);
        await controller.leave();
      },
    );
  });

  /// The strip only ever mounts at compact width, so every test pins that
  /// viewport. Its share notice is said in words, not left to a small
  /// glyph a tooltip has to explain: the collapsed strip is exactly where
  /// a live share is easiest to miss.
  group('the collapsed strip', () {
    testWidgets('names the share in words for a live share', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceStripIndicator(), harness.container),
      );
      await tester.pump();
      await controller.setScreenShare(true);
      await tester.pump();

      expect(find.textContaining('sharing'), findsOneWidget);
      await controller.leave();
    });

    testWidgets('stays quiet for a share only requested, not live', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = FakeSession(
        screenShareOutcome: ScreenShareOutcome.pendingBroadcast,
      );
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceStripIndicator(), harness.container),
      );
      await tester.pump();
      await controller.setScreenShare(true);
      await tester.pump();

      expect(controller.state.awaitingBroadcast, isTrue);
      expect(find.textContaining('sharing'), findsNothing);

      // Clears the pending-broadcast deadline and heartbeat timers.
      await controller.leave();
    });

    testWidgets('stays quiet with no share at all', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);

      await tester.pumpWidget(
        _harness(const VoiceStripIndicator(), harness.container),
      );
      await tester.pump();

      expect(find.textContaining('sharing'), findsNothing);
      await controller.leave();
    });
  });
}
