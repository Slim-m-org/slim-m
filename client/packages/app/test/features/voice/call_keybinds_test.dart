// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Call keybinds are off until the person turns them on: nothing is bound in
/// the window or registered with the OS, someone who remapped keeps theirs on,
/// and each shortcut can be cleared.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/global_hotkeys_controller.dart';
import 'package:slimm_app/src/features/voice/providers/shortcut_overrides.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_shortcuts_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import 'global_hotkeys_harness.dart';
import 'voice_controller_harness.dart';

const _enabledKey = 'slimm.voice.call_keybinds_enabled';
const _overridesKey = 'slimm.voice.shortcut_overrides';
const _ctrlU = SingleActivator(LogicalKeyboardKey.keyU, control: true);

Future<ProviderContainer> _loaded() async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(shortcutOverridesProvider);
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return container;
}

void main() {
  tearDown(() => userShortcutOverrides = const {});

  group('defaults and migration', () {
    test(
      'a fresh install has call keybinds off and no call chord bound',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = await _loaded();
        expect(container.read(shortcutOverridesProvider).enabled, isFalse);
        for (final action in remappableActions) {
          expect(activatorFor(action), isNull, reason: action.name);
        }
        expect(describeAppAction(AppAction.toggleMuteCall), isEmpty);
        expect(activatorFor(AppAction.quickSwitch), isNotNull);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(_enabledKey), isFalse);
      },
    );

    test('someone who already remapped a shortcut keeps keybinds on', () async {
      SharedPreferences.setMockInitialValues({
        _overridesKey: encodeOverrides({AppAction.toggleMuteCall: _ctrlU}),
      });
      final container = await _loaded();
      expect(container.read(shortcutOverridesProvider).enabled, isTrue);
      expect(describeAppAction(AppAction.toggleMuteCall), ['Ctrl', 'U']);
      expect(describeAppAction(AppAction.toggleDeafenCall), isNotEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_enabledKey), isTrue);
    });

    test('turning keybinds on offers the defaults, off unbinds them', () async {
      SharedPreferences.setMockInitialValues({});
      final container = await _loaded();
      final notifier = container.read(shortcutOverridesProvider.notifier);
      await notifier.setEnabled(true);
      expect(describeAppAction(AppAction.toggleMuteCall), [
        'Ctrl',
        'Shift',
        'M',
      ]);
      await notifier.setEnabled(false);
      expect(activatorFor(AppAction.toggleMuteCall), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_enabledKey), isFalse);
    });

    test('a cleared shortcut stays cleared after a restart', () async {
      SharedPreferences.setMockInitialValues({_enabledKey: true});
      final container = await _loaded();
      await container
          .read(shortcutOverridesProvider.notifier)
          .clear(AppAction.leaveCall);
      expect(activatorFor(AppAction.leaveCall), isNull);

      userShortcutOverrides = const {};
      final reopened = await _loaded();
      expect(reopened.read(shortcutOverridesProvider).overrides, {
        AppAction.leaveCall: null,
      });
      expect(activatorFor(AppAction.leaveCall), isNull);
      expect(activatorFor(AppAction.toggleMuteCall), isNotNull);
    });
  });

  group('settings', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const Scaffold(
              body: SingleChildScrollView(child: VoiceShortcutsSection()),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      return container;
    }

    testWidgets('the chords show only once call keybinds are on', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester);
      expect(find.text('Keybinds'), findsOneWidget);
      expect(find.text('Call keybinds'), findsOneWidget);
      expect(find.text('Mute shortcut'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Call keybinds').last);
      await pumpFrames(tester);
      expect(find.text('Mute shortcut'), findsOneWidget);
      expect(find.text('Ctrl+Shift+M'), findsOneWidget);
    });

    testWidgets('Clear leaves a shortcut with no key', (tester) async {
      SharedPreferences.setMockInitialValues({_enabledKey: true});
      final container = await pump(tester);
      await tester.tap(find.bySemanticsLabel('Clear Mute shortcut'));
      await pumpFrames(tester);
      expect(find.text('Ctrl+Shift+M'), findsNothing);
      expect(find.text('None'), findsOneWidget);
      expect(
        container.read(shortcutOverridesProvider).overrides,
        containsPair(AppAction.toggleMuteCall, null),
      );
      expect(find.bySemanticsLabel('Clear Mute shortcut'), findsNothing);
    });
  });

  group('system-wide registration', () {
    final harness = VoiceHarness();
    tearDown(harness.dispose);

    Future<({FakeHotkeySource source, VoiceController voice})> inCall(
      WidgetTester tester,
    ) async {
      final source = FakeHotkeySource();
      final session = FakeSession();
      final voice = harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: [globalHotkeySourceProvider.overrideWithValue(source)],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: const MaterialApp(
            home: PushToTalkListener(child: Scaffold(body: SizedBox())),
          ),
        ),
      );
      await pumpFrames(tester);
      expect(source.binds, isEmpty, reason: 'nothing is grabbed at startup');
      await voice.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await pumpFrames(tester);
      return (source: source, voice: voice);
    }

    testWidgets(
      'with keybinds and push to talk off, a call registers nothing',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final c = await inCall(tester);
        expect(c.source.binds, isEmpty);
        await c.voice.leave();
      },
    );

    testWidgets('a cleared call shortcut is not registered', (tester) async {
      SharedPreferences.setMockInitialValues({
        _enabledKey: true,
        _overridesKey: encodeOverrides({AppAction.toggleMuteCall: null}),
      });
      final c = await inCall(tester);
      expect(c.source.binds.last, [GlobalHotkeyId.toggleDeafen]);
      await c.voice.leave();
    });

    testWidgets('turning keybinds off mid-call unregisters them', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({_enabledKey: true});
      final c = await inCall(tester);
      expect(c.source.binds.last, [
        GlobalHotkeyId.toggleMute,
        GlobalHotkeyId.toggleDeafen,
      ]);
      await harness.container
          .read(shortcutOverridesProvider.notifier)
          .setEnabled(false);
      await pumpFrames(tester);
      expect(c.source.binds.last, isEmpty);
      await c.voice.leave();
    });
  });
}
