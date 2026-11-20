// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The engine every call runs on, covering what livekit_client 2.13.1 leaves
/// undone when the signal socket drops around a publish; see decision 0075.
library;

// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/core/engine.dart' as lk_engine;
// ignore: implementation_imports
import 'package:livekit_client/src/internal/events.dart' as lk_events;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
// ignore: implementation_imports
import 'package:livekit_client/src/types/internal.dart' as lk_internal;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'publish_withdrawal.dart';
import 'stereo_share_engine.dart';
import 'stuck_offer.dart';

class CallEngine extends lk_engine.Engine {
  CallEngine({
    required super.roomOptions,
    super.peerConnectionCreate,
    super.signalClient,
    super.connectOptions = const lk.ConnectOptions(),
    Duration stuckOfferGrace = kStuckOfferGrace,
    @visibleForTesting bool Function()? signalLive,
  }) {
    _stuckOffer = StuckOfferWatch(
      pendingOffer: () => pendingOffer(publisher?.pc),
      signalLive: signalLive ?? _signalLive,
      escalate: _restartForStuckOffer,
      grace: stuckOfferGrace,
    );
    events.on<lk_events.EngineResumedEvent>((_) => _stuckOffer.watch());
    onDispose(() async => _stuckOffer.cancel());
  }

  bool _signalLive() =>
      !isClosed && signalClient.connectionState == lk.ConnectionState.connected;

  /// A closed engine reconnects no further, so the room must hear the disconnect that closed it.
  ///
  /// `Room` drops an engine disconnect while a full reconnect runs, so a leave closing the engine mid-restart left a dead call on screen.
  @override
  bool get isFullReconnectInProgress =>
      !isClosed && super.isFullReconnectInProgress;

  late final StuckOfferWatch _stuckOffer;

  /// A publish whose answer never comes may already be sending: its sender is
  /// taken off the publisher, so nothing leaves that no publication can mute.
  @override
  Future<lk_models.TrackInfo> addTrack(lk_rtc.AddTrackRequest req) async {
    markShareAudioStereo(req);
    try {
      return await super.addTrack(req);
    } catch (_) {
      await _withdraw(req.cid);
      rethrow;
    }
  }

  Future<void> _withdraw(String cid) async {
    final pc = publisher?.pc;
    if (pc == null) return;
    try {
      if (!await withdrawSender(pc, cid)) return;
      AppLog.warning(
        LogTag.voice,
        'A publish got no answer; took its track off the connection',
      );
      await negotiate();
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not take a failed publish off the connection',
        error,
        stack,
      );
    }
  }

  /// An offer still unanswered when a resume starts lost its answer with the
  /// socket, and the SDK's resume cannot recover from that: restart instead.
  @override
  Future<void> resumeConnection(
    lk_internal.ClientDisconnectReason reason, {
    lk_models.ReconnectReason? reconnectReason,
  }) async {
    if (await pendingOffer(publisher?.pc) != null) {
      fullReconnectOnNext = true;
      throw lk.NegotiationError(
        'an offer was unanswered when the signal connection dropped',
      );
    }
    return super.resumeConnection(reason, reconnectReason: reconnectReason);
  }

  /// The offer out when a resume finished is still out: it went to the dead
  /// socket, and livekit waits on its answer before it negotiates again.
  void _restartForStuckOffer() {
    if (isClosed) return;
    AppLog.warning(
      LogTag.voice,
      'An offer sent before a resume was never answered; restarting the connection',
    );
    fullReconnectOnNext = true;
    unawaited(
      handleReconnect(
        lk_internal.ClientDisconnectReason.negotiationFailed,
        reconnectReason: lk_models.ReconnectReason.RR_UNKNOWN,
      ),
    );
  }
}
