// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call this device was in comes back after the app restarts itself or
/// crashes within five minutes, and never after a deliberate leave or quit.
library;

import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/features/voice/providers/transcription_notice.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_elsewhere.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../support/fake_voice.dart';

/// Puts the call in [flags], the way the controller would as a call moves.
void _setFlags(ProviderContainer container, VoiceFlags flags) =>
    (container.read(voiceControllerProvider.notifier) as FakeVoiceController)
        .set(
          VoiceState(
            channelId: flags.channelId,
            state: flags.state,
            microphoneEnabled: flags.microphoneEnabled,
            deafened: flags.deafened,
          ),
        );

const _connected = VoiceFlags(
  channelId: 'voice-1',
  state: VoiceSessionState.connected,
);

class _Notice implements TranscriptionNoticeActions {
  const _Notice({required this.due});

  final bool due;

  @override
  Future<bool> isDue() async => due;

  @override
  Future<TranscriptionNotice?> dueNotice() async => due
      ? const TranscriptionNotice(
          mode: CallTranscriptionMode.always,
          acknowledged: false,
        )
      : null;

  @override
  Future<void> acknowledge() async {}
}

/// The field [key] of the stored record, read raw so a field the record drops reads as missing.
Object? _stored(SharedPreferences prefs, String key) {
  final raw = prefs.getString(callRestoreKey);
  return raw == null ? null : (jsonDecode(raw) as Map<String, dynamic>)[key];
}

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
  bool onScreen = true,
  bool noticeDue = false,
  String userId = 'user-1',
  List<CallToRestore>? rejoins,
  VoiceController Function(Ref ref) voice = FakeVoiceController.new,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: TokenPair(
            userId: userId,
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      preferencesProvider.overrideWith((ref) async => prefs),
      voiceControllerProvider.overrideWith(voice),
      restorableChannelProvider.overrideWithValue((_) async => channelName),
      voiceElsewhereCheckProvider.overrideWithValue((_) async => elsewhere),
      accountActiveProvider.overrideWith((ref) => onScreen),
      transcriptionNoticeActionsProvider.overrideWithValue(
        _Notice(due: noticeDue),
      ),
      if (rejoins != null)
        rejoinRestoredCallProvider.overrideWithValue(
          (call) async => rejoins.add(call),
        ),
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
      await restore.forget('user-1');

      expect((await restore.take('user-1'))?.restart, isTrue);
    });

    test(
      "forgetting one account's call leaves another account's record",
      () async {
        final prefs = await _prefs({
          callRestoreKey: _record(user: 'user-2', at: now),
        });
        await CallRestore(prefs, now: () => now).forget('user-1');
        expect(prefs.getString(callRestoreKey), isNotNull);

        await CallRestore(prefs, now: () => now).forget('user-2');
        expect(prefs.getString(callRestoreKey), isNull);
      },
    );

    test('a relaunch that fails gives the call back to this run', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final restore = CallRestore(prefs, now: () => now);
      await expectLater(
        restore.relaunchKeepingCall(() async => throw StateError('no spawn')),
        throwsStateError,
      );
      await restore.forget('user-1');
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

    test('deafen is kept through a restart and one that fails', () async {
      final prefs = await _prefs({
        callRestoreKey: jsonEncode({
          'channel': 'voice-1',
          'user': 'user-1',
          'at': now.toIso8601String(),
          'muted': true,
          'deafened': true,
        }),
      });
      final restore = CallRestore(prefs, now: () => now);

      await restore.markRestart();
      expect(_stored(prefs, 'deafened'), isTrue);
      expect(_stored(prefs, 'restart'), isTrue);

      await restore.abandonRestart();
      expect(_stored(prefs, 'deafened'), isTrue);
      expect(_stored(prefs, 'restart'), isFalse);
    });

    test('an unreadable record is ignored', () async {
      final prefs = await _prefs({callRestoreKey: '{not json'});
      expect(await CallRestore(prefs, now: () => now).take('user-1'), isNull);
    });
  });

  group('the watcher', () {
    testWidgets('a mute with the window in the tray reaches the record with '
        'no frame drawn', (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final prefs = await _prefs();
      final container = _container(prefs);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      container.read(callRestoreWatchProvider);
      _setFlags(container, _connected);
      await tester.pump();
      expect(_stored(prefs, 'muted'), isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(SchedulerBinding.instance.framesEnabled, isFalse);
      _setFlags(
        container,
        const VoiceFlags(
          channelId: 'voice-1',
          state: VoiceSessionState.connected,
          microphoneEnabled: false,
        ),
      );
      await tester.idle();

      expect(_stored(prefs, 'muted'), isTrue);
      _setFlags(container, const VoiceFlags());
      await tester.idle();
    });

    testWidgets('a restored call is deafened again when it connects with the '
        'window in the tray', (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      late FakeVoiceController voice;
      final container = _container(
        await _prefs(),
        voice: (ref) => voice = FakeVoiceController(
          ref,
          recording: true,
          joinOutcome: const VoiceState(channelId: 'voice-1', joining: true),
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      final rejoined = container.read(rejoinRestoredCallProvider)(
        CallToRestore(
          channelId: 'voice-1',
          userId: 'user-1',
          at: now,
          muted: false,
          deafened: true,
        ),
      );
      await tester.idle();
      _setFlags(container, _connected);
      await tester.idle();

      expect(voice.calls, ['join:voice-1', 'deafen']);
      await rejoined;
    });

    test('a connected call is written, and leaving it forgets it', () async {
      final prefs = await _prefs();
      final container = _container(prefs);
      container.read(callRestoreWatchProvider);
      _setFlags(
        container,
        const VoiceFlags(
          channelId: 'voice-1',
          state: VoiceSessionState.connected,
          microphoneEnabled: false,
        ),
      );
      await pumpEventQueue();
      final written = CallToRestore.decode(prefs.getString(callRestoreKey));
      expect(written?.channelId, 'voice-1');
      expect(written?.muted, isTrue);

      _setFlags(container, const VoiceFlags());
      await pumpEventQueue();
      expect(prefs.getString(callRestoreKey), isNull);
    });

    test(
      "one account leaving does not delete the call another account holds",
      () async {
        final prefs = await _prefs();
        final first = _container(prefs);
        final second = _container(prefs, userId: 'user-2');
        first.read(callRestoreWatchProvider);
        second.read(callRestoreWatchProvider);
        _setFlags(first, _connected);
        await pumpEventQueue();
        _setFlags(second, _connected);
        await pumpEventQueue();
        expect(_stored(prefs, 'user'), 'user-2');

        _setFlags(first, const VoiceFlags());
        await pumpEventQueue();

        expect(_stored(prefs, 'user'), 'user-2');
      },
    );

    test('a join that never connected forgets nothing', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final other = _container(prefs, userId: 'user-2');
      other.read(callRestoreWatchProvider);
      _setFlags(
        other,
        const VoiceFlags(
          channelId: 'voice-2',
          state: VoiceSessionState.connecting,
        ),
      );
      _setFlags(other, const VoiceFlags());
      await pumpEventQueue();

      expect(prefs.getString(callRestoreKey), isNotNull);
    });

    test('deafening alone rewrites the record', () async {
      final prefs = await _prefs();
      final container = _container(prefs);
      container.read(callRestoreWatchProvider);
      _setFlags(container, _connected);
      await pumpEventQueue();
      expect(_stored(prefs, 'deafened'), isFalse);

      _setFlags(
        container,
        const VoiceFlags(
          channelId: 'voice-1',
          state: VoiceSessionState.connected,
          deafened: true,
        ),
      );
      await pumpEventQueue();

      expect(_stored(prefs, 'deafened'), isTrue);
    });

    test('starting with no call leaves the last crash for the gate', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: now)});
      final container = _container(prefs);
      container.read(callRestoreWatchProvider);
      _setFlags(container, const VoiceFlags(state: VoiceSessionState.failed));
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

    test('the offer stays stored until it is answered', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: DateTime.now())});
      final container = _container(prefs);

      expect(await container.read(callToRestoreProvider)(), isNotNull);
      expect(
        await container.read(callToRestoreProvider)(),
        isNotNull,
        reason: 'a reload before Rejoin or Not now must ask again',
      );
      await container.read(answerCallToRestoreProvider)();
      expect(await container.read(callToRestoreProvider)(), isNull);
    });

    test('an offer past five minutes is cleared', () async {
      final prefs = await _prefs({
        callRestoreKey: _record(
          at: DateTime.now().subtract(const Duration(minutes: 6)),
        ),
      });

      expect(await _container(prefs).read(callToRestoreProvider)(), isNull);
      expect(prefs.getString(callRestoreKey), isNull);
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

    test('a live call keeps its own record', () async {
      final prefs = await _prefs({callRestoreKey: _record(at: DateTime.now())});
      final container = _container(prefs);
      _setFlags(container, _connected);

      expect(await container.read(callToRestoreProvider)(), isNull);
      expect(
        prefs.getString(callRestoreKey),
        isNotNull,
        reason: 'a restart straight after must still find the call',
      );
    });
  });

  group('a Space out of view', () {
    Future<(SharedPreferences, List<CallToRestore>)> start({
      bool restart = true,
      bool onScreen = false,
      bool noticeDue = false,
    }) async {
      final prefs = await _prefs({
        callRestoreKey: _record(at: DateTime.now(), restart: restart),
      });
      final rejoins = <CallToRestore>[];
      final container = _container(
        prefs,
        onScreen: onScreen,
        noticeDue: noticeDue,
        rejoins: rejoins,
      );
      await container.read(offScreenCallRestoreProvider)();
      return (prefs, rejoins);
    }

    test('rejoins a call the app restarted itself out of', () async {
      final (prefs, rejoins) = await start();

      expect([for (final call in rejoins) call.channelId], ['voice-1']);
      expect(prefs.getString(callRestoreKey), isNull);
    });

    test('leaves a crashed call for when the Space is opened', () async {
      final (prefs, rejoins) = await start(restart: false);

      expect(rejoins, isEmpty);
      expect(prefs.getString(callRestoreKey), isNotNull);
    });

    test('leaves the call while the transcription notice is owed', () async {
      final (prefs, rejoins) = await start(noticeDue: true);

      expect(rejoins, isEmpty);
      expect(prefs.getString(callRestoreKey), isNotNull);
    });

    test('the Space on screen leaves it to the gate', () async {
      final (prefs, rejoins) = await start(onScreen: true);

      expect(rejoins, isEmpty);
      expect(prefs.getString(callRestoreKey), isNotNull);
    });
  });
}
