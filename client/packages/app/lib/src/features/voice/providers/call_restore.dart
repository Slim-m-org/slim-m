// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call this device was in when the app went away, so the next start can
/// bring it back: on its own after the app restarted itself, by asking after
/// a crash. A deliberate leave or quit forgets it (owner, 2026-11-15).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../providers/providers.dart';
import '../../accounts/providers/account_slot.dart' show accountActiveProvider;
import 'transcription_notice.dart';
import 'voice_controller.dart';
import 'voice_elsewhere.dart';
import 'voice_flags.dart';

const callRestoreKey = 'slimm.voice.call_in_progress';

/// How long after the app went away a call is still worth coming back to.
const callRestoreWindow = Duration(minutes: 5);

/// How often a live call refreshes its record, so a crash is dated to within this.
const callRestoreRefresh = Duration(seconds: 30);

class CallToRestore {
  const CallToRestore({
    required this.channelId,
    required this.userId,
    required this.at,
    required this.muted,
    this.deafened = false,
    this.restart = false,
  });

  final String channelId;
  final String userId;
  final DateTime at;
  final bool muted;
  final bool deafened;

  /// The app restarted itself, so the call comes back without asking.
  final bool restart;

  String encode() => jsonEncode({
    'channel': channelId,
    'user': userId,
    'at': at.toUtc().toIso8601String(),
    'muted': muted,
    'deafened': deafened,
    'restart': restart,
  });

  static CallToRestore? decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return CallToRestore(
        channelId: json['channel'] as String,
        userId: json['user'] as String,
        at: DateTime.parse(json['at'] as String),
        muted: json['muted'] as bool,
        deafened: json['deafened'] as bool? ?? false,
        restart: json['restart'] as bool? ?? false,
      );
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Ignored an unreadable call to bring back',
        error,
        stack,
      );
      return null;
    }
  }

  CallToRestore restarting(DateTime now) => _with(at: now, restart: true);

  CallToRestore _with({required DateTime at, required bool restart}) =>
      CallToRestore(
        channelId: channelId,
        userId: userId,
        at: at,
        muted: muted,
        deafened: deafened,
        restart: restart,
      );
}

class CallRestore {
  CallRestore(this._prefs, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final SharedPreferences _prefs;
  final DateTime Function() _now;

  /// Process-wide: once the app is restarting or quitting, a call torn down on the way out says nothing.
  static bool _closing = false;

  @visibleForTesting
  static void resetClosing() => _closing = false;

  Future<void> remember({
    required String channelId,
    required String userId,
    required bool muted,
    bool deafened = false,
  }) async {
    if (_closing) return;
    final call = CallToRestore(
      channelId: channelId,
      userId: userId,
      at: _now(),
      muted: muted,
      deafened: deafened,
    );
    await _prefs.setString(callRestoreKey, call.encode());
  }

  Future<void> forget() async {
    if (_closing) return;
    await _prefs.remove(callRestoreKey);
  }

  /// The app is about to restart itself, so the call it is in comes back on its own.
  Future<void> markRestart() async {
    _closing = true;
    final call = CallToRestore.decode(_prefs.getString(callRestoreKey));
    if (call == null) return;
    await _prefs.setString(callRestoreKey, call.restarting(_now()).encode());
  }

  /// The restart did not happen after all: the call is this process's again, and asks if it crashes.
  Future<void> abandonRestart() async {
    _closing = false;
    final call = CallToRestore.decode(_prefs.getString(callRestoreKey));
    if (call == null || !call.restart) return;
    await _prefs.setString(
      callRestoreKey,
      call._with(at: call.at, restart: false).encode(),
    );
  }

  /// Marks the call to come back, runs [relaunch], and takes the mark back if it throws.
  Future<void> relaunchKeepingCall(Future<void> Function() relaunch) async {
    await markRestart();
    try {
      await relaunch();
    } catch (_) {
      await abandonRestart();
      rethrow;
    }
  }

  /// The app is quitting on purpose, so nothing comes back.
  Future<void> markQuit() async {
    _closing = true;
    await _prefs.remove(callRestoreKey);
  }

  /// [userId]'s call to bring back, left where it is; null when there is none.
  CallToRestore? peek(String userId) {
    final call = CallToRestore.decode(_prefs.getString(callRestoreKey));
    return call != null && call.userId == userId ? call : null;
  }

  /// [userId]'s call to bring back, kept until it is answered; an expired one is cleared and null.
  Future<CallToRestore?> offer(String userId) async {
    final call = peek(userId);
    if (call == null) return null;
    final age = _now().difference(call.at);
    if (!age.isNegative && age <= callRestoreWindow) return call;
    await _prefs.remove(callRestoreKey);
    return null;
  }

  /// [userId]'s call to bring back, cleared as it is read; null when there is none or it is too old.
  Future<CallToRestore?> take(String userId) async {
    final call = await offer(userId);
    if (call != null) await _prefs.remove(callRestoreKey);
    return call;
  }
}

final callRestoreProvider = FutureProvider<CallRestore>(
  (ref) async => CallRestore(await ref.watch(preferencesProvider.future)),
);

/// Keeps the record current while a call is connected, and forgets it when the call is left.
final callRestoreWatchProvider = Provider<void>((ref) {
  Timer? refresh;
  Future<void> sync(VoiceFlags? before, VoiceFlags now) async {
    final restore = await ref.read(callRestoreProvider.future);
    final channelId = now.channelId;
    if (channelId == null) {
      refresh?.cancel();
      refresh = null;
      if (before?.channelId != null) await restore.forget();
      return;
    }
    final userId = ref.read(apiProvider).session.tokens?.userId;
    if (now.state != VoiceSessionState.connected || userId == null) return;
    await restore.remember(
      channelId: channelId,
      userId: userId,
      muted: !now.microphoneEnabled,
      deafened: now.deafened,
    );
    refresh ??= Timer.periodic(
      callRestoreRefresh,
      (_) => unawaited(sync(null, ref.read(voiceFlagsAtOnce))),
    );
  }

  // A mute made with the window in the tray, which draws no frames, must reach the record before an update restart.
  ref.listen<VoiceFlags>(voiceFlagsAtOnce, (before, now) {
    if (before?.channelId == now.channelId &&
        before?.state == now.state &&
        before?.microphoneEnabled == now.microphoneEnabled &&
        before?.deafened == now.deafened) {
      return;
    }
    unawaited(sync(before, now));
  });
  ref.onDispose(() => refresh?.cancel());
});

/// The voice channel a restored call can rejoin, by name; null when it is gone or is not a voice channel.
final restorableChannelProvider =
    Provider<Future<String?> Function(String channelId)>(
      (ref) => (channelId) async {
        final store = await ref.read(storeProvider.future);
        final row = await store.channelRow(channelId);
        return row != null && row.kind == 'voice' ? row.name : null;
      },
    );

typedef RestorableCall = ({CallToRestore call, String channelName});

/// The call to bring back on this start; null when there is none. It stays
/// stored until [answerCallToRestoreProvider], so a reload before an answer offers it again.
final callToRestoreProvider = Provider<Future<RestorableCall?> Function()>(
  (ref) => () async {
    final userId = ref.read(apiProvider).session.tokens?.userId;
    // A live call's record is its own, kept current by the watch, not one to bring back.
    if (userId == null || ref.read(voiceFlagsProvider).channelId != null) {
      return null;
    }
    final restore = await ref.read(callRestoreProvider.future);
    final call = await restore.offer(userId);
    if (call == null) return null;
    final name = await ref.read(restorableChannelProvider)(call.channelId);
    if (ref.read(voiceFlagsProvider).channelId != null) return null;
    // Gone, or back in a call on another device by now, which a rejoin here would take away.
    if (name == null ||
        await ref.read(voiceElsewhereCheckProvider)(call.channelId) != null) {
      await restore.take(userId);
      return null;
    }
    return (call: call, channelName: name);
  },
);

/// Clears the call on offer once it is rejoined or turned down.
final answerCallToRestoreProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    final userId = ref.read(apiProvider).session.tokens?.userId;
    if (userId == null) return;
    await (await ref.read(callRestoreProvider.future)).take(userId);
  },
);

/// Joins a restored call as it was left: muted if it was, and deafened again once it connects.
final rejoinRestoredCallProvider =
    Provider<Future<void> Function(CallToRestore call)>(
      (ref) => (call) async {
        final voice = ref.read(voiceControllerProvider.notifier);
        await (call.muted
            ? voice.joinMuted(call.channelId)
            : voice.join(call.channelId));
        if (!call.deafened) return;
        if (!await _connects(ref, call.channelId)) return;
        if (!ref.read(voiceFlagsProvider).deafened) await voice.toggleDeafen();
      },
    );

/// Whether the call in [channelId] reaches connected, which can be after a retry; false once it ends instead.
Future<bool> _connects(Ref ref, String channelId) async {
  final outcome = Completer<bool>();
  final flags = ref.listen<VoiceFlags>(voiceFlagsProvider, (_, now) {
    if (outcome.isCompleted) return;
    if (now.channelId != channelId) {
      outcome.complete(false);
    } else if (now.state == VoiceSessionState.connected) {
      outcome.complete(true);
    }
  }, fireImmediately: true);
  try {
    return await outcome.future;
  } finally {
    flags.close();
  }
}

/// Brings back a call the app restarted itself out of in a Space that is not
/// on screen. One that has to ask first waits for its Space to be opened.
final offScreenCallRestoreProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    if (ref.read(accountActiveProvider)) return;
    final userId = ref.read(apiProvider).session.tokens?.userId;
    if (userId == null) return;
    final restore = await ref.read(callRestoreProvider.future);
    if (restore.peek(userId)?.restart != true) return;
    if (await ref.read(transcriptionNoticeActionsProvider).isDue()) return;
    final found = await ref.read(callToRestoreProvider)();
    if (found == null) return;
    await ref.read(answerCallToRestoreProvider)();
    await ref.read(rejoinRestoredCallProvider)(found.call);
  },
);
