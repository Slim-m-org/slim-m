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
    this.restart = false,
  });

  final String channelId;
  final String userId;
  final DateTime at;
  final bool muted;

  /// The app restarted itself, so the call comes back without asking.
  final bool restart;

  String encode() => jsonEncode({
    'channel': channelId,
    'user': userId,
    'at': at.toUtc().toIso8601String(),
    'muted': muted,
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

  CallToRestore restarting(DateTime now) => CallToRestore(
    channelId: channelId,
    userId: userId,
    at: now,
    muted: muted,
    restart: true,
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
  }) async {
    if (_closing) return;
    final call = CallToRestore(
      channelId: channelId,
      userId: userId,
      at: _now(),
      muted: muted,
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
      CallToRestore(
        channelId: call.channelId,
        userId: call.userId,
        at: call.at,
        muted: call.muted,
      ).encode(),
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

  /// [userId]'s call to bring back, cleared as it is read; null when there is none or it is too old.
  Future<CallToRestore?> take(String userId) async {
    final call = CallToRestore.decode(_prefs.getString(callRestoreKey));
    if (call == null || call.userId != userId) return null;
    await _prefs.remove(callRestoreKey);
    final age = _now().difference(call.at);
    if (age.isNegative || age > callRestoreWindow) return null;
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
    );
    refresh ??= Timer.periodic(
      callRestoreRefresh,
      (_) => unawaited(sync(null, ref.read(voiceFlagsProvider))),
    );
  }

  ref.listen<VoiceFlags>(voiceFlagsProvider, (before, now) {
    if (before?.channelId == now.channelId &&
        before?.state == now.state &&
        before?.microphoneEnabled == now.microphoneEnabled) {
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

/// The call to bring back on this start, read once; null when there is nothing to bring back.
final callToRestoreProvider = Provider<Future<RestorableCall?> Function()>(
  (ref) => () async {
    final userId = ref.read(apiProvider).session.tokens?.userId;
    if (userId == null) return null;
    final restore = await ref.read(callRestoreProvider.future);
    final call = await restore.take(userId);
    if (call == null) return null;
    final name = await ref.read(restorableChannelProvider)(call.channelId);
    if (name == null || ref.read(voiceFlagsProvider).channelId != null) {
      return null;
    }
    // Back in a call on another device by now, which a rejoin here would take away.
    if (await ref.read(voiceElsewhereCheckProvider)(call.channelId) != null) {
      return null;
    }
    return (call: call, channelName: name);
  },
);
