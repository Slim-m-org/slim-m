// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetching a call token and opening the SFU session for it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_api/api.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../api_failure.dart';
import '../../../providers/providers.dart';
import 'join_timings_provider.dart';
import 'voice_input_settings.dart';
import 'voice_join_muted.dart';
import 'voice_sfu_security.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';

const _joinCallTask = 'join the call';

class VoiceSfuConnect {
  VoiceSfuConnect(
    this._session,
    this._ref,
    this._access,
    this._joinMuted,
    this._input,
  );

  final VoiceSession _session;
  final Ref _ref;
  final VoiceStateAccess _access;
  final VoiceJoinMuted _joinMuted;
  final VoiceInputSettings _input;

  VoiceState get _current => _access.state;

  /// Connects, turns a refusal into the failure the call shows, and clears `joining` unless a newer call took over.
  Future<void> run(
    String channelId,
    bool mutedByCaller,
    bool Function() superseded,
  ) async {
    try {
      await connect(channelId, mutedByCaller, superseded);
    } on api.NotConfiguredException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'This server has no voice set up',
        error,
        stack,
      );
      failJoin(superseded, 'This Space has no voice configured.');
    } on api.ForbiddenException catch (error, stack) {
      api.reportFailure(api.LogTag.voice, _joinCallTask, error, stack);
      failJoin(superseded, 'You do not have permission to join this channel.');
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.voice, _joinCallTask, e, stack);
      failJoin(
        superseded,
        describeApiFailure(_joinCallTask, e),
        retryable: true,
      );
    } catch (e) {
      // Joining is automatic now, so nothing asks first; an exception no other clause names must still fail cleanly.
      if (!superseded()) {
        api.AppLog.at(
          api.LogLevel.error,
          api.LogTag.voice,
          'Could not join the call',
          error: e,
        );
      }
      failJoin(superseded, 'Could not join the call.', retryable: true);
    } finally {
      if (!superseded()) {
        _access.state = _current.copyWith(joining: false);
      }
    }
  }

  /// Asks for a token and opens the session; every write is dropped once [superseded] says a newer call took over.
  Future<void> connect(
    String channelId,
    bool mutedByCaller,
    bool Function() superseded,
  ) async {
    final timings = _ref.read(joinTimingsProvider)
      ..mark(JoinStage.tokenRequested);
    final token = await _ref.read(apiProvider).voiceToken(channelId);
    timings.mark(JoinStage.tokenReceived);
    final mutedByChannel = await _joinMuted.asksFor(_ref, channelId);
    if (superseded()) return;
    final insecureReason = insecureSfuReason(token.url);
    if (insecureReason != null) {
      _access.state = _current.copyWith(
        state: VoiceSessionState.failed,
        error: insecureReason,
        retryable: false,
      );
      return;
    }
    _access.state = _current.copyWith(canPublish: token.canPublish);
    if (mutedByChannel || mutedByCaller) {
      _access.state = _joinMuted.showMuted(_current);
    }
    // Push-to-talk joins closed: it opens only while the key is held; see setPushToTalkPreference.
    final microphoneAtJoin =
        _current.microphoneEnabled &&
        token.canPublish &&
        !_input.pushToTalkEnabled;
    await _session.join(
      url: token.url,
      token: token.token,
      // A token that cannot publish gets no mic or camera request, which would only fail.
      microphoneEnabled: microphoneAtJoin,
      cameraEnabled: _current.cameraEnabled && token.canPublish,
      canPublish: token.canPublish,
    );
    if (superseded()) return;
    // Show the push-to-talk-closed mic in the button; scoped to PTT so the canPublish path is untouched.
    if (_input.pushToTalkEnabled && _current.microphoneEnabled) {
      _access.state = _current.copyWith(microphoneEnabled: false);
    }
    if (_session.state == VoiceSessionState.failed) {
      _access.state = _current.copyWith(
        error: 'Could not connect to the call. ${_session.lastError ?? ''}'
            .trim(),
      );
    }
  }

  void failJoin(
    bool Function() superseded,
    String error, {
    bool retryable = false,
  }) {
    if (superseded()) return;
    _ref.read(joinTimingsProvider).finish();
    _access.state = _current.copyWith(
      state: VoiceSessionState.failed,
      error: error,
      retryable: retryable,
    );
  }
}
