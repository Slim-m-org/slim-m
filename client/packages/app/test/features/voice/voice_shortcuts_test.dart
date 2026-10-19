// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0076: mute, deafen and push to talk are remappable in Voice
/// settings, refuse a key something else already uses, persist, and reset.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/shortcut_overrides.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/key_capture_row.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_shortcuts_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

bool _focusIsInRow(String title) {
  var found = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    final widget = e.widget;
    found = widget is KeyCaptureRow && widget.title == title;
    return !found;
  });
  return found;
}

const _ctrlU = SingleActivator(LogicalKeyboardKey.keyU, control: true);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => userShortcutOverrides = const {});

  group('rules', () {
    test('a bare letter is refused, a modifier or an F key is not', () {
      expect(
        shortcutRuleViolation(const SingleActivator(LogicalKeyboardKey.keyU)),
        isNotNull,
      );
      expect(shortcutRuleViolation(_ctrlU), isNull);
      expect(
        shortcutRuleViolation(const SingleActivator(LogicalKeyboardKey.f9)),
        isNull,
      );
      expect(
        shortcutRuleViolation(
          const SingleActivator(LogicalKeyboardKey.keyU, shift: true),
        ),
        isNotNull,
        reason: 'shift alone still types a capital letter',
      );
    });

    test('a chord another action owns is a conflict, a free one is not', () {
      final taken = shortcutConflict(
        chord: const SingleActivator(LogicalKeyboardKey.keyK, control: true),
        action: AppAction.toggleMuteCall,
        pushToTalkKey: LogicalKeyboardKey.keyV,
      );
      expect(taken, 'Quick switcher');
      expect(
        shortcutConflict(
          chord: _ctrlU,
          action: AppAction.toggleMuteCall,
          pushToTalkKey: LogicalKeyboardKey.keyV,
        ),
        isNull,
      );
    });

    test('an action never conflicts with its own current chord', () {
      final own = activatorFor(AppAction.toggleMuteCall)! as SingleActivator;
      expect(
        shortcutConflict(
          chord: own,
          action: AppAction.toggleMuteCall,
          pushToTalkKey: LogicalKeyboardKey.keyV,
        ),
        isNull,
      );
    });

    test('mute and deafen conflict with each other once remapped', () {
      final deafenKey = activatorFor(AppAction.toggleDeafenCall)!;
      expect(
        shortcutConflict(
          chord: deafenKey as SingleActivator,
          action: AppAction.toggleMuteCall,
          pushToTalkKey: LogicalKeyboardKey.keyV,
        ),
        'Deafen or undeafen',
      );
    });

    test('a bare F key conflicts with the push-to-talk key and back', () {
      const f9 = SingleActivator(LogicalKeyboardKey.f9);
      expect(
        shortcutConflict(
          chord: f9,
          action: AppAction.toggleMuteCall,
          pushToTalkKey: LogicalKeyboardKey.f9,
        ),
        'Push to talk',
      );
      expect(
        pushToTalkConflict(
          LogicalKeyboardKey.f9,
          overrides: {AppAction.toggleMuteCall: f9},
        ),
        'Mute or unmute',
      );
    });

    test('a chord survives being stored and read back', () {
      final decoded = decodeOverrides(
        encodeOverrides({AppAction.toggleDeafenCall: _ctrlU}),
      );
      expect(sameChord(decoded[AppAction.toggleDeafenCall]!, _ctrlU), isTrue);
      expect(decodeOverrides('not json'), isEmpty);
      expect(decodeOverrides(null), isEmpty);
    });
  });

  group('controller', () {
    test('a remap reaches activatorFor and survives a restart', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(shortcutOverridesProvider.notifier)
          .set(AppAction.toggleMuteCall, _ctrlU);
      final now = activatorFor(AppAction.toggleMuteCall)! as SingleActivator;
      expect(sameChord(now, _ctrlU), isTrue);
      expect(describeAppAction(AppAction.toggleMuteCall), ['Ctrl', 'U']);

      userShortcutOverrides = const {};
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      reopened.read(shortcutOverridesProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        reopened.read(shortcutOverridesProvider)[AppAction.toggleMuteCall],
        isNotNull,
      );
      expect(describeAppAction(AppAction.toggleMuteCall), ['Ctrl', 'U']);
    });

    test('reset puts the defaults back', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(shortcutOverridesProvider.notifier);
      await notifier.set(AppAction.toggleMuteCall, _ctrlU);
      await notifier.reset();
      expect(describeAppAction(AppAction.toggleMuteCall), [
        'Ctrl',
        'Shift',
        'M',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('slimm.voice.shortcut_overrides'), isNull);
    });
  });

  group('settings rows', () {
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
      await tester.pumpAndSettle();
      return container;
    }

    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool control = false,
    }) async {
      if (control) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      }
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      if (control) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('Change takes the next chord and shows it', (tester) async {
      final container = await pump(tester);
      expect(find.text('Ctrl+Shift+M'), findsOneWidget);
      await tester.tap(find.text('Change').first);
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyU, control: true);
      expect(find.text('Ctrl+U'), findsOneWidget);
      expect(
        container.read(shortcutOverridesProvider)[AppAction.toggleMuteCall],
        isNotNull,
      );
    });

    testWidgets('a taken chord is refused and capture keeps waiting', (
      tester,
    ) async {
      final container = await pump(tester);
      await tester.tap(find.text('Change').first);
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyK, control: true);
      expect(find.text('Already used for Quick switcher.'), findsOneWidget);
      expect(container.read(shortcutOverridesProvider), isEmpty);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('a bare key is refused and a lone modifier is waited out', (
      tester,
    ) async {
      final container = await pump(tester);
      await tester.tap(find.text('Change').first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Cancel'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.keyU);
      expect(find.textContaining('Hold Ctrl, Alt or Cmd'), findsOneWidget);
      expect(container.read(shortcutOverridesProvider), isEmpty);
    });

    testWidgets('Escape cancels and keeps the old chord', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Change').first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Ctrl+Shift+M'), findsOneWidget);
    });

    testWidgets('the whole capture works from the keyboard', (tester) async {
      final container = await pump(tester);
      var tabs = 0;
      while (!_focusIsInRow('Deafen shortcut') && tabs++ < 12) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Cancel'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.keyU, control: true);
      expect(
        container.read(shortcutOverridesProvider)[AppAction.toggleDeafenCall],
        isNotNull,
      );
    });

    testWidgets('Reset appears once something changed and restores it', (
      tester,
    ) async {
      final container = await pump(tester);
      expect(find.text('Reset shortcuts'), findsNothing);
      await container
          .read(shortcutOverridesProvider.notifier)
          .set(AppAction.toggleDeafenCall, _ctrlU);
      await container
          .read(voiceSettingsControllerProvider.notifier)
          .setPushToTalkKey(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset shortcuts'));
      await tester.pumpAndSettle();
      expect(container.read(shortcutOverridesProvider), isEmpty);
      expect(
        container.read(voiceSettingsControllerProvider).pushToTalkKey,
        LogicalKeyboardKey.keyV,
      );
      expect(find.text('Reset shortcuts'), findsNothing);
    });
  });
}
