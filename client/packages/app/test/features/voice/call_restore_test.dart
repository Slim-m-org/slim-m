// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call this device was in comes back after the app restarts itself or
/// crashes within five minutes, and never after a deliberate leave or quit.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/features/voice/providers/voice_elsewhere.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _flags = StateProvider<VoiceFlags>((ref) => const VoiceFlags());

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

String _record({
  String user = 'user-1',
  required DateTime at,
  bool restart = false,
  bool muted = false,
}) => CallToRestore(
  channelId: 'voice-1',
  userId: user,
  at: at,
  muted: muted,
  restart: restart,
).encode();

ProviderContainer _container(
  SharedPreferences prefs, {
  String? channelName = 'Lounge',
  String? elsewhere,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      preferencesProvider.overrideWith((ref) async => prefs),
      voiceFlagsProvider.overrideWith((ref) => ref.watch(_flags)),
      restorableChannelProvider.overrideWithValue((_) async => channelName),
      voiceElsewhereCheckProvider.overrideWithValue((_) async => elsewhere),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final now = DateTime.utc(2026, 11, 15, 12);
  setUp(CallRestore.resetClosing);

  group('CallRestore', () {
    test('a remembered call is handed back once', () async {
      final prefs = await _prefs();
      final restore = CallRestore(prefs, now: () => now);
      await restore.remember(
        channelId: 'voice-1',
        userId: 'user-1',
        muted: true,
      );

      final call = await restore.take('user-1');
      expect(call?.channelId, 'voice-1');
      expect(call?.muted, isTrue);
      expect(call?.restart, isFalse);
      expect(await restore.take('user-1'), isNull);
    });

    test('a call older than five minutes stays gone', () async {
      final prefs = await _prefs({
        callRestoreKey: _record(at: now.subtract(const Duration(minutes: 6))),
      });
      expect(await CallRestore(prefs, now: () => now).take('user-1'), isNull);
    });

    test("another account's call is left for that account", () async {
      final prefs = await _prefs({
        callRestoreKey: _record(user: 'user-2', at: now),
      });
      expect(await CallRestore(prefs, now: () => now).take('user-1'), isNull);
      expect(prefs.getString(callRestoreKey), isNotNull);
    });

    test('a restart marks the call to come back on its own', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final restore = CallRestore(prefs, now: () => now);
      await restore.markRestart();
      // The call torn down on the way out must not wipe it.
      await restore.forget();

      expect((await restore.take('user-1'))?.restart, isTrue);
    });

    test('a relaunch that fails gives the call back to this run', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final restore = CallRestore(prefs, now: () => now);
      await expectLater(
        restore.relaunchKeepingCall(() async => throw StateError('no spawn')),
        throwsStateError,
      );
      await restore.forget();
      expect(
        prefs.getString(callRestoreKey),
        isNull,
        reason: 'leaving the call still forgets it',
      );
      await restore.remember(
        channelId: 'voice-1',
        userId: 'user-1',
        muted: false,
      );
      expect((await restore.take('user-1'))?.restart, isFalse);
    });

    test('a quit forgets the call, and nothing after it writes one', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final restore = CallRestore(prefs, now: () => now);
      await restore.markQuit();
      await restore.remember(
        channelId: 'voice-1',
        userId: 'user-1',
        muted: false,
      );

      expect(prefs.getString(callRestoreKey), isNull);
    });

    test('an unreadable record is ignored', () async {
      final prefs = await _prefs({callRestoreKey: '{not json'});
      expect(await CallRestore(prefs, now: () => now).take('user-1'), isNull);
    });
  });

  group('the watcher', () {
    test('a connected call is written, and leaving it forgets it', () async {
      final prefs = await _prefs();
      final container = _container(prefs);
      container.read(callRestoreWatchProvider);
      container.read(_flags.notifier).state = const VoiceFlags(
        channelId: 'voice-1',
        state: VoiceSessionState.connected,
        microphoneEnabled: false,
      );
      await pumpEventQueue();
      final written = CallToRestore.decode(prefs.getString(callRestoreKey));
      expect(written?.channelId, 'voice-1');
      expect(written?.muted, isTrue);

      container.read(_flags.notifier).state = const VoiceFlags();
      await pumpEventQueue();
      expect(prefs.getString(callRestoreKey), isNull);
    });

    test('starting with no call leaves the last crash for the gate', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final container = _container(prefs);
      container.read(callRestoreWatchProvider);
      container.read(_flags.notifier).state = const VoiceFlags(
        state: VoiceSessionState.failed,
      );
      await pumpEventQueue();

      expect(prefs.getString(callRestoreKey), isNotNull);
    });
  });

  group('callToRestoreProvider', () {
    test('a recent call comes back with its channel name', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: DateTime.now())});
      final found = await _container(prefs).read(callToRestoreProvider)();

      expect(found?.call.channelId, 'voice-1');
      expect(found?.channelName, 'Lounge');
    });

    test('nothing comes back while in a call on another device', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: DateTime.now())});
      final container = _container(prefs, elsewhere: 'voice-1');

      expect(await container.read(callToRestoreProvider)(), isNull);
    });

    test('nothing comes back for a channel that is gone', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: DateTime.now())});
      final container = _container(prefs, channelName: null);

      expect(await container.read(callToRestoreProvider)(), isNull);
    });
  });
}
