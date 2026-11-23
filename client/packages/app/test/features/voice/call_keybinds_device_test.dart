// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call keybinds switch is one per device: every signed-in server follows
/// it, and it governs only a desktop build, which binds system-wide.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host_factory.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/voice/providers/global_hotkeys_controller.dart';
import 'package:slimm_app/src/features/voice/providers/shortcut_overrides.dart';
import 'package:slimm_app/src/features/voice/widgets/push_to_talk_listener.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import 'global_hotkeys_harness.dart';
import 'voice_controller_harness.dart';

const _enabledKey = 'slimm.voice.call_keybinds_enabled';
const _ctrlU = SingleActivator(LogicalKeyboardKey.keyU, control: true);

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _container(List<Override> overrides) {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  container.read(shortcutOverridesProvider);
  return container;
}

void main() {
  tearDown(() => userShortcutOverrides = const {});

  group('where nothing binds system-wide', () {
    final notDesktop = [callKeybindsOptInProvider.overrideWithValue(false)];

    test('a fresh install keeps the default call shortcuts', () async {
      SharedPreferences.setMockInitialValues({});
      _container(notDesktop);
      await _settle();
      final mute = activatorFor(AppAction.toggleMuteCall);
      expect(mute, isA<SingleActivator>());
      expect(chordLabel(mute! as SingleActivator), 'Ctrl+Shift+M');
      expect(resolveBindings().values, contains(AppAction.toggleMuteCall));
    });

    test('a stored off does not unbind them either', () async {
      SharedPreferences.setMockInitialValues({_enabledKey: false});
      _container(notDesktop);
      await _settle();
      for (final action in remappableActions) {
        expect(activatorFor(action), isNotNull, reason: action.name);
      }
    });
  });

  group('one switch for every signed-in server', () {
    final harness = VoiceHarness();
    tearDown(harness.dispose);

    test('every server the app opens reads the same switch', () {
      final host = createAccountHost(
        DesktopWindowShell(),
        Uri.parse(officialServer),
      );
      ProviderContainer open() {
        final container = host.createContainer(
          AccountSlot(chooseServer: (_, _) => throw UnimplementedError()),
        );
        addTearDown(container.dispose);
        return container;
      }

      expect(
        open().read(callKeybindsStoreProvider),
        same(open().read(callKeybindsStoreProvider)),
      );
    });

    testWidgets('turning keybinds off in one server unbinds another server\'s '
        'call', (tester) async {
      SharedPreferences.setMockInitialValues({_enabledKey: true});
      final device = CallKeybindsStore();
      addTearDown(device.dispose);
      final shared = [callKeybindsStoreProvider.overrideWithValue(device)];
      final source = FakeHotkeySource();
      final session = FakeSession();
      final voice = harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: [
          ...shared,
          globalHotkeySourceProvider.overrideWithValue(source),
        ],
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
      await voice.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await pumpFrames(tester);
      expect(source.binds.last, [
        GlobalHotkeyId.toggleMute,
        GlobalHotkeyId.toggleDeafen,
        GlobalHotkeyId.markCall,
      ]);

      final other = _container(shared);
      await tester.runAsync(_settle);
      await other.read(shortcutOverridesProvider.notifier).setEnabled(false);
      await pumpFrames(tester);
      expect(source.binds.last, isEmpty);
      expect(
        harness.container.read(shortcutOverridesProvider).enabled,
        isFalse,
      );

      await harness.container
          .read(shortcutOverridesProvider.notifier)
          .set(AppAction.toggleMuteCall, _ctrlU);
      await pumpFrames(tester);
      expect(
        activatorFor(AppAction.toggleMuteCall),
        isNull,
        reason: 'a remap in a server with a stale switch must not turn it on',
      );
      expect(other.read(shortcutOverridesProvider).overrides, {
        AppAction.toggleMuteCall: _ctrlU,
      });
      expect(source.binds.last, isEmpty);
      await voice.leave();
    });
  });
}
