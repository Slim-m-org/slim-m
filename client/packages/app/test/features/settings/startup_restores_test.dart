// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A truncated preferences file must not strand the splash.
///
/// `SharedPreferences.getInstance()` throws on a corrupt file, every launch,
/// and the voice restores in the bootstrap did not catch it, so the app sat on
/// "Loading preferences" for good. These run the real restores against a real
/// Linux preferences store holding a truncated file.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog;
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;
import 'package:slimm_app/src/desktop/providers/desktop_splash_preference.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/startup_restores.dart';

/// A container whose preferences read throws what `getInstance()` throws on a
/// truncated file: a [FormatException] out of `json.decode`.
ProviderContainer _unreadable() {
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => Future<SharedPreferences>.error(
          const FormatException('Unterminated string', '{"flutter.slimm.voice'),
        ),
      ),
    ],
  );
  return _wired(container);
}

ProviderContainer _wired(ProviderContainer container) {
  AppLog.install(container.read(debugLogProvider.notifier));
  addTearDown(() {
    AppLog.install(null);
    container.dispose();
  });
  return container;
}

/// A container over a readable preferences store holding [values].
Future<ProviderContainer> _readable(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [preferencesProvider.overrideWith((ref) async => prefs)],
  );
  return _wired(container);
}

/// The names of the restores [_recorded] saw fail, e.g. `voice processing`.
Set<String> _failedRestores(ProviderContainer container) => {
  for (final message in _recorded(container))
    if (RegExp(r'saved (.+) setting').firstMatch(message) case final m?)
      m.group(1)!,
};

List<String> _recorded(ProviderContainer container) => [
  for (final event in container.read(debugLogProvider))
    if (event.message.startsWith('Could not restore the saved') ||
        event.message.startsWith('Startup step'))
      event.message,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('with an unreadable preferences file', () {
    test('every startup restore completes instead of rejecting', () async {
      final container = _unreadable();

      await restoreStartupPreferences(container);
    });

    test('each controller keeps its default', () async {
      final container = _unreadable();

      await restoreStartupPreferences(container);

      expect(
        container.read(themeControllerProvider),
        AppThemeChoice.spaceDefault,
      );
      expect(
        container.read(timeFormatControllerProvider),
        TimeFormatPreference.system,
      );
    });

    test('each restore that could not read it is recorded', () async {
      final container = _unreadable();

      await restoreStartupPreferences(container);

      final recorded = _recorded(container).join('\n');
      for (final name in [
        'camera on join',
        'voice activity sensitivity',
        'push to talk',
        'audio devices',
      ]) {
        expect(recorded, contains('saved $name setting'));
      }
    });

    test('the splash duration falls back to its default floor', () async {
      final container = _unreadable();

      final floor = await restoreSplashFloor(
        container,
        (c) => splashFloorFor(c.read(splashDurationControllerProvider)),
      );

      expect(floor, splashFloorFor(SplashDuration.standard));
    });
  });

  group('with a readable preferences file', () {
    test('a stored choice still restores, with nothing recorded', () async {
      final container = await _readable({themeChoiceKey: 'dark'});

      await restoreStartupPreferences(container);

      expect(container.read(themeControllerProvider), AppThemeChoice.dark);
      expect(_recorded(container), isEmpty);
    });
  });

  group('resyncVoiceDevicePreferences', () {
    test('re-reads every device-wide voice setting startup does', () async {
      final startup = _unreadable();
      await restoreStartupPreferences(startup);
      final startupVoice = _failedRestores(
        startup,
      ).difference({for (final name in restorablePreferences.keys) name});

      final switched = _unreadable();
      await resyncVoiceDevicePreferences(switched);

      expect(
        _failedRestores(switched),
        startupVoice.difference({'participant volumes', 'hidden cameras'}),
      );
      expect(_failedRestores(switched), hasLength(11));
    });

    test('leaves a live call alone', () async {
      final container = _unreadable();
      final inCall = ProviderContainer(
        parent: container,
        overrides: [
          voiceFlagsProvider.overrideWithValue(
            const VoiceFlags(state: VoiceSessionState.connected),
          ),
        ],
      );
      addTearDown(inCall.dispose);

      await resyncVoiceDevicePreferences(inCall);

      expect(_recorded(container), isEmpty);
    });
  });

  group('a resync while a call is live', () {
    final inCall = StateProvider<bool>((ref) => true);

    ProviderContainer wired(ProviderContainer parent) {
      final container = ProviderContainer(
        parent: parent,
        overrides: [
          voiceFlagsProvider.overrideWith(
            (ref) => ref.watch(inCall)
                ? const VoiceFlags(state: VoiceSessionState.connected)
                : const VoiceFlags(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('runs once the call ends instead of being dropped', () async {
      final parent = _unreadable();
      final container = wired(parent);
      await resyncVoiceDevicePreferences(container);
      expect(_recorded(parent), isEmpty);

      container.read(inCall.notifier).state = false;
      await pumpEventQueue();

      expect(_failedRestores(parent), hasLength(11));
    });

    test('a switch to another channel is not the call ending', () async {
      final flags = StateProvider<VoiceFlags>(
        (ref) => const VoiceFlags(state: VoiceSessionState.connected),
      );
      final parent = _unreadable();
      final container = ProviderContainer(
        parent: parent,
        overrides: [voiceFlagsProvider.overrideWith((ref) => ref.watch(flags))],
      );
      addTearDown(container.dispose);
      await resyncVoiceDevicePreferences(container);

      container.read(flags.notifier).state = const VoiceFlags(
        channelId: 'next',
        state: VoiceSessionState.connecting,
        joining: true,
      );
      await pumpEventQueue();
      expect(_recorded(parent), isEmpty);

      container.read(flags.notifier).state = const VoiceFlags();
      await pumpEventQueue();
      expect(_failedRestores(parent), hasLength(11));
    });

    test('a second resync does not queue a second one', () async {
      final parent = _unreadable();
      final container = wired(parent);
      await resyncVoiceDevicePreferences(container);
      await resyncVoiceDevicePreferences(container);

      container.read(inCall.notifier).state = false;
      await pumpEventQueue();

      expect(_failedRestores(parent), hasLength(11));
      expect(_recorded(parent), hasLength(11));
    });
  });

  group('runStartupStep', () {
    test('a step that throws is recorded and does not escape', () async {
      final container = _wired(ProviderContainer());

      await runStartupStep(container, 'update check', () async {
        throw StateError('boom');
      });

      expect(
        _recorded(container).single,
        contains('Startup step "update check" failed'),
      );
    });

    test('a step that works runs and records nothing', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var ran = false;

      await runStartupStep(container, 'update check', () async => ran = true);

      expect(ran, isTrue);
      expect(_recorded(container), isEmpty);
    });
  });
}
