// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module hearing a call as text (decision 0105): whether one is asking or
/// listening in a channel, and the three things a person in the call can do
/// about it. The route gives the state, the `voice.call_audio` frame keeps it
/// current, and a reconnect asks again, since a frame missed while offline
/// would leave a banner on for a session that ended.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

/// What the call knows about call audio right now.
class CallAudioModel {
  const CallAudioModel({
    this.status = const api.CallAudioStatus(),
    this.ended,
    this.error,
    this.busy = false,
  });

  final api.CallAudioStatus status;

  /// How the last session ended (`declined`, `lapsed`, `stopped`, ...), until
  /// the next one starts. Never says who declined.
  final String? ended;

  /// A refused request, kept until the next attempt.
  final String? error;
  final bool busy;

  api.CallAudioState? get session => status.session;

  CallAudioModel copyWith({
    api.CallAudioStatus? status,
    String? ended,
    bool clearEnded = false,
    String? error,
    bool clearError = false,
    bool? busy,
  }) => CallAudioModel(
    status: status ?? this.status,
    ended: clearEnded ? null : ended ?? this.ended,
    error: clearError ? null : error ?? this.error,
    busy: busy ?? this.busy,
  );
}

class CallAudioController
    extends AutoDisposeFamilyNotifier<CallAudioModel, String> {
  late String channelId;
  bool _disposed = false;

  api.SlimmApi get _api => ref.read(apiProvider);

  @override
  CallAudioModel build(String arg) {
    channelId = arg;
    final events = ref.read(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      unawaited(events.cancel());
    });
    ref.listen(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) {
        unawaited(refresh());
      }
    });
    unawaited(Future<void>.microtask(refresh));
    return const CallAudioModel();
  }

  void _onEvent(api.ServerEvent event) {
    if (event is! api.VoiceCallAudioChanged || event.channelId != channelId) {
      return;
    }
    final session = event.state;
    state = state.copyWith(
      status: api.CallAudioStatus(
        session: session,
        startable: state.status.startable,
      ),
      ended: event.ended,
      clearEnded: session != null,
    );
    if (session == null) unawaited(refresh());
  }

  /// Reads the state again; a deployment without the feature reads as none.
  Future<void> refresh() async {
    try {
      final status = await _api.callAudio(channelId);
      if (!_disposed) state = state.copyWith(status: status);
    } on api.ApiException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Call audio is not available for this channel',
        error,
        stack,
      );
      if (!_disposed) {
        state = state.copyWith(status: const api.CallAudioStatus());
      }
    }
  }

  void clearEnded() => state = state.copyWith(clearEnded: true);

  Future<void> request(String moduleId) =>
      _act(() => _api.requestCallAudio(channelId, moduleId));

  Future<void> answer({required bool allow}) =>
      _act(() => _api.answerCallAudio(channelId, allow: allow));

  Future<void> stop() => _act(() async {
    await _api.stopCallAudio(channelId);
    return null;
  });

  Future<void> _act(Future<api.CallAudioStatus?> Function() call) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await call();
      if (_disposed) return;
      state = state.copyWith(
        busy: false,
        status: status == null
            ? null
            : api.CallAudioStatus(
                session: status.session,
                startable: state.status.startable,
              ),
      );
      if (status == null || status.session == null) unawaited(refresh());
    } on api.ApiException catch (error) {
      if (!_disposed) state = state.copyWith(busy: false, error: error.message);
    }
  }
}

/// [channelId]'s call-audio state, kept current while anything watches it.
final callAudioProvider = NotifierProvider.autoDispose
    .family<CallAudioController, CallAudioModel, String>(
      CallAudioController.new,
    );
