// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's one-time hints: the share button's long press on a phone, and
/// the microphone a call opened. Each shows once, floats over the dock without
/// resizing it, and comes back only when it says something new.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/call_dock_hint.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_dock.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_hint.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _connected = VoiceFlags(state: VoiceSessionState.connected);
const _usb = AudioDevice(id: 'usb-1', label: 'USB headset');
const _savedInputKey = 'slimm.voice.audio_input_device_id';

InertSession _withInputs() => InertSession(
  supportsAudioInputSelection: true,
  audioInputDeviceList: const [_usb],
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  InertSession? session,
  bool touch = true,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final width = touch ? 390.0 : 900.0;
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = await pumpVoiceCallDock(
    tester,
    _connected,
    width: width,
    touch: touch,
    session: session,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return container;
}

/// A dock card with a row above the one the mic anchor sits in, as a bot's
/// controls or a folded canvas toggle give it.
Future<void> _pumpTwoRowCard(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: _withInputs()),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FloatingDockCard(
              rows: [
                SizedBox(width: 200, height: 40),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DockHintAnchor(
                      target: DockHintTarget.mic,
                      child: SizedBox(width: 48, height: 48),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Future<void> _elapse(WidgetTester tester) async {
  await tester.pump(dockHintDuration + const Duration(seconds: 1));
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

class _CountingSession extends InertSession {
  _CountingSession() : super(supportsAudioInputSelection: true);

  int inputListings = 0;

  @override
  Future<List<AudioDevice>> audioInputDevices() async {
    inputListings++;
    return super.audioInputDevices();
  }
}

Future<void> _resize(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 700);
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  group('resolving', () {
    testWidgets('does not list devices again while the window resizes', (
      tester,
    ) async {
      final session = _CountingSession();
      SharedPreferences.setMockInitialValues({
        shareHintSeenKey: true,
        micCueSeenKey: '',
      });
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpVoiceCallDock(
        tester,
        _connected,
        width: 900,
        scoped: false,
        session: session,
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      final mounted = session.inputListings;
      expect(mounted, greaterThan(0));

      for (final width in [880.0, 820.0, 760.0, 700.0, 960.0]) {
        await _resize(tester, width);
      }
      expect(session.inputListings, mounted);
    });

    testWidgets('resolves again when the density flips', (tester) async {
      SharedPreferences.setMockInitialValues({micCueSeenKey: ''});
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpVoiceCallDock(
        tester,
        _connected,
        width: 900,
        scoped: false,
        session: _withInputs(),
      );
      await _resize(tester, 900);
      expect(find.text(shareHintText), findsNothing);

      await _resize(tester, 390);
      expect(find.text(shareHintText), findsOneWidget);
    });
  });

  group('the share hint', () {
    testWidgets('names the long press on a phone, once per install', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text(shareHintText), findsOneWidget);

      await _elapse(tester);
      expect(find.text(shareHintText), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(shareHintSeenKey), isTrue);
    });

    testWidgets('stays away from a pointer-width dock, which has a caret', (
      tester,
    ) async {
      await _pump(tester, touch: false);
      expect(find.text(shareHintText), findsNothing);
      expect(find.byTooltip('Screen share options'), findsOneWidget);
    });

    testWidgets('stays away once it was seen', (tester) async {
      await _pump(tester, prefs: {shareHintSeenKey: true});
      expect(find.text(shareHintText), findsNothing);
    });

    testWidgets('lets a tap through to what it covers', (tester) async {
      await _pump(tester);
      final text = tester.renderObject(find.text(shareHintText));

      final hit = tester.hitTestOnBinding(
        tester.getCenter(find.text(shareHintText)),
      );
      expect(hit.path.any((entry) => entry.target == text), isFalse);
    });

    testWidgets('floats over the dock without resizing it', (tester) async {
      await _pump(tester, prefs: {shareHintSeenKey: true});
      final quiet = tester.getSize(find.byKey(VoiceCallDock.slideKey));

      await tester.pumpWidget(const SizedBox());
      await _pump(tester);
      expect(find.text(shareHintText), findsOneWidget);
      expect(tester.getSize(find.byKey(VoiceCallDock.slideKey)), quiet);
    });
  });

  group('the mic cue', () {
    testWidgets('names the system default on the first call', (tester) async {
      await _pump(tester, session: _withInputs(), touch: false);
      expect(find.text('Mic: System default'), findsOneWidget);
    });

    testWidgets('clears a row above the control', (tester) async {
      SharedPreferences.setMockInitialValues({shareHintSeenKey: true});
      await _pumpTwoRowCard(tester);
      final text = find.text('Mic: System default');
      expect(text, findsOneWidget);
      final bubble = find
          .ancestor(of: text, matching: find.byType(DecoratedBox))
          .first;
      final cardTop = tester.getTopLeft(find.byType(FloatingDockCard)).dy;
      expect(tester.getBottomLeft(bubble).dy, lessThanOrEqualTo(cardTop));
    });

    testWidgets('names a saved microphone that was not shown yet', (
      tester,
    ) async {
      await _pump(
        tester,
        prefs: {_savedInputKey: 'usb-1', micCueSeenKey: ''},
        session: _withInputs(),
        touch: false,
      );
      expect(find.text('Mic: USB headset'), findsOneWidget);
    });

    testWidgets('stays away for a microphone already shown', (tester) async {
      await _pump(
        tester,
        prefs: {_savedInputKey: 'usb-1', micCueSeenKey: 'usb-1'},
        session: _withInputs(),
        touch: false,
      );
      expect(find.textContaining('Mic:'), findsNothing);
    });

    testWidgets('is remembered after it was on screen', (tester) async {
      await _pump(tester, session: _withInputs(), touch: false);
      await _elapse(tester);

      expect(find.textContaining('Mic:'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(micCueSeenKey), '');
    });

    testWidgets('stays away where the platform picks the microphone', (
      tester,
    ) async {
      await _pump(tester, touch: false);
      expect(find.textContaining('Mic:'), findsNothing);
    });

    testWidgets('gives way to the share hint on a phone, one at a time', (
      tester,
    ) async {
      await _pump(tester, session: _withInputs());
      expect(find.text('Mic: System default'), findsOneWidget);
      expect(find.text(shareHintText), findsNothing);

      await _elapse(tester);
      expect(find.text('Mic: System default'), findsNothing);
      expect(find.text(shareHintText), findsOneWidget);
    });
  });
}
