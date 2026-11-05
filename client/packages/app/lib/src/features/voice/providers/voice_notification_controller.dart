// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which voice channels this account asked to hear about, held for the session.
///
/// A view of the server's answer (`/voice-notifications/channels`), not a second source of
/// truth: a channel absent here is off. Every change round-trips through the API and rolls back
/// when it fails, so the menu never claims a choice the server did not take.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

class VoiceNotificationState {
  const VoiceNotificationState({this.byChannel = const {}});

  final Map<String, api.VoiceNotification> byChannel;

  /// [channelId]'s choice, off when none was made.
  api.VoiceNotification forChannel(String channelId) =>
      byChannel[channelId] ??
      api.VoiceNotification(
        channelId: channelId,
        joins: api.VoiceJoinMode.off,
        streams: false,
      );
}

class VoiceNotificationController extends Notifier<VoiceNotificationState> {
  var _disposed = false;

  @override
  VoiceNotificationState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(Future.microtask(refresh));
    return const VoiceNotificationState();
  }

  Future<void> refresh() async {
    try {
      final choices = await ref.read(apiProvider).listVoiceNotifications();
      if (_disposed) return;
      state = VoiceNotificationState(
        byChannel: {for (final c in choices) c.channelId: c},
      );
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'refresh voice notification settings',
        error,
        stack,
      );
    }
  }

  Future<void> setJoins(String channelId, api.VoiceJoinMode joins) =>
      _set(channelId, joins: joins);

  Future<void> setStreams(String channelId, {required bool streams}) =>
      _set(channelId, streams: streams);

  Future<void> _set(
    String channelId, {
    api.VoiceJoinMode? joins,
    bool? streams,
  }) async {
    final before = state.byChannel;
    final current = state.forChannel(channelId);
    final next = api.VoiceNotification(
      channelId: channelId,
      joins: joins ?? current.joins,
      streams: streams ?? current.streams,
    );
    final after = {...before};
    if (next.joins == api.VoiceJoinMode.off && !next.streams) {
      after.remove(channelId);
    } else {
      after[channelId] = next;
    }
    state = VoiceNotificationState(byChannel: after);
    try {
      await ref
          .read(apiProvider)
          .setVoiceNotification(
            channelId,
            joins: next.joins,
            streams: next.streams,
          );
    } catch (_) {
      if (!_disposed) state = VoiceNotificationState(byChannel: before);
      rethrow;
    }
  }
}

/// Session-long, like the channel overrides it sits beside.
final voiceNotificationProvider =
    NotifierProvider<VoiceNotificationController, VoiceNotificationState>(
      VoiceNotificationController.new,
    );
