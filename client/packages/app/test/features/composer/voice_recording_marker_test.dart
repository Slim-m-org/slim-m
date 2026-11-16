// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message recording in a channel not on screen shows a marker in the
/// shell, the rail's footer on a wide window and a bottom strip on a phone,
/// which goes back to its composer and goes away once the recording stops.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart'
    show channelRailExpandedProvider;
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_voice_bar.dart';
import 'package:slimm_app/src/features/composer/widgets/voice_recording_marker.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';
import 'voice_recording_test.dart' show FakeCapture;

final _marker = find.byKey(voiceRecordingMarkerKey);
final _record = find.byTooltip('Record a voice message');
final _bar = find.byKey(const Key('composer-voice-bar'));

Finder _inMarker(String text) =>
    find.descendant(of: _marker, matching: find.text(text));

/// The real shell at [size], open on #design.
class _Shell {
  _Shell(this.tester);

  final WidgetTester tester;
  final captures = <FakeCapture>[];
  late final ({ProviderContainer container, SlimmDatabase db}) fixture;
  late final GoRouter router;
  DateTime clock = DateTime(2026, 1, 1);

  ProviderContainer get container => fixture.container;
  String get path => router.routerDelegate.currentConfiguration.uri.path;

  Future<void> open(Size size, {List<Override> overrides = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    fixture = await fixtureContainer(
      extraOverrides: [
        voiceRecordingNeedsToolsProvider.overrideWithValue(false),
        voiceRecordingYieldsToCallProvider.overrideWithValue(false),
        voiceCaptureFactoryProvider.overrideWithValue(() {
          final capture = FakeCapture();
          captures.add(capture);
          return capture;
        }),
        ...overrides,
      ],
    );
    router = fixtureRouter('/channels/c-design');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Taps the mic of the channel on screen.
  Future<void> record(String channelId) async {
    container.read(voiceRecorderProvider(channelId).notifier).now = () => clock;
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(_record);
    await tester.pump();
    await tester.pump();
  }

  Future<void> go(String channelId) async {
    router.go('/channels/$channelId');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> elapse(Duration by) async {
    clock = clock.add(by);
    await tester.pump(kVoiceTick);
    await tester.pump();
  }

  Future<void> close() => teardownFixture(tester, container, fixture.db);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the rail marks a recording elsewhere, goes back to it, and '
      'hides once it stops', (tester) async {
    final shell = _Shell(tester);
    await shell.open(const Size(1280, 900));
    await shell.record('c-design');
    expect(_marker, findsNothing, reason: 'its composer is on screen');

    await shell.go('c-general');
    await shell.elapse(const Duration(seconds: 12));
    expect(_inMarker('Recording in #design'), findsOneWidget);
    expect(_inMarker('0:12'), findsOneWidget);

    await tester.tap(_marker);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(shell.path, '/channels/c-design');
    expect(_marker, findsNothing);
    expect(_bar, findsOneWidget);

    await shell.go('c-general');
    expect(_marker, findsOneWidget);
    await shell.container.read(callStartYieldsProvider).callStarting();
    await tester.pump();
    expect(_marker, findsNothing, reason: 'a kept clip needs no marker');
    expect(
      shell.container.read(voiceRecorderProvider('c-design')).clip,
      isNotNull,
    );
    await shell.close();
  });

  testWidgets('a collapsed rail keeps the channel over the words', (
    tester,
  ) async {
    final shell = _Shell(tester);
    await shell.open(
      const Size(1280, 900),
      overrides: [channelRailExpandedProvider.overrideWith((ref) => false)],
    );
    await shell.record('c-design');
    await shell.go('c-general');

    expect(_inMarker('#design'), findsOneWidget);
    expect(_inMarker('Recording in #design'), findsNothing);
    await shell.close();
  });

  testWidgets('a thread whose pane closed is marked, and docks again', (
    tester,
  ) async {
    final shell = _Shell(tester);
    await shell.open(const Size(1280, 900));
    final thread = shell.container.read(openThreadProvider.notifier);
    thread.state = 'c-thread';
    await tester.pump(const Duration(milliseconds: 350));
    shell.container.read(voiceRecorderProvider('c-thread').notifier).now = () =>
        shell.clock;
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(_record.last);
    await tester.pump();
    expect(shell.container.read(recordingVoiceChannelProvider), 'c-thread');
    expect(_marker, findsNothing, reason: 'the docked thread shows it');

    thread.state = null;
    await tester.pump(const Duration(milliseconds: 350));
    expect(_inMarker('Recording a voice message'), findsOneWidget);

    await tester.tap(_marker);
    await tester.pump(const Duration(milliseconds: 350));
    expect(thread.state, 'c-thread');
    expect(shell.path, '/channels/c-design');
    expect(_marker, findsNothing);
    await shell.close();
  });

  testWidgets("a phone's bottom strip marks a recording elsewhere and goes "
      'back to it', (tester) async {
    final shell = _Shell(tester);
    await shell.open(const Size(390, 844));
    await shell.record('c-design');
    expect(_marker, findsNothing);

    await shell.go('c-general');
    expect(_inMarker('Recording in #design'), findsOneWidget);
    expect(
      tester.getBottomLeft(_marker).dy,
      844,
      reason: 'it sits on the bottom edge',
    );

    await tester.tap(_marker);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(shell.path, '/channels/c-design');
    expect(_marker, findsNothing);
    await shell.close();
  });

  testWidgets('recording in a second channel stops the first, whose clip '
      'waits in its own channel', (tester) async {
    final shell = _Shell(tester);
    await shell.open(const Size(1280, 900));
    await shell.record('c-design');
    await shell.elapse(const Duration(seconds: 5));

    await shell.go('c-general');
    expect(_marker, findsOneWidget);
    await shell.record('c-general');
    expect(
      _marker,
      findsNothing,
      reason: 'the recording on screen is #general',
    );
    expect(shell.captures.first.stopped, isTrue);

    await shell.go('c-design');
    expect(find.descendant(of: _bar, matching: find.text('0:05')), findsOne);
    expect(
      shell.container.read(voiceRecorderProvider('c-design')).phase,
      VoicePhase.stopped,
    );
    await shell.close();
  });
}
