// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Telling an offer the server will never answer from one still on its way.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// How long an offer may stay unanswered over a live signal connection.
const kStuckOfferGrace = Duration(seconds: 5);

/// Which offer [pc] is waiting on an answer for, or null when it has none out.
Future<String?> pendingOffer(rtc.RTCPeerConnection? pc) async {
  if (pc == null) return null;
  try {
    final state = await pc.getSignalingState();
    if (state != rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      return null;
    }
    return offerIdentity((await pc.getLocalDescription())?.sdp ?? '');
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.voice,
      'Read no pending offer; the connection is likely closed',
      error,
      stack,
    );
    return null;
  }
}

/// The origin line of [sdp], which names the session and counts its offers.
///
/// The whole description will not do: a browser writes each ICE candidate it
/// gathers into the pending offer, so the same offer reads longer a second later.
String offerIdentity(String sdp) => sdp
    .split('\n')
    .map((line) => line.trim())
    .firstWhere((line) => line.startsWith('o='), orElse: () => '');

/// After a resume, finds the offer that went out on the dead socket.
///
/// livekit parks a publisher whose offer is unanswered and waits for the
/// answer before negotiating again. An offer the socket dropped is never
/// answered, so every later publish waits behind it for the rest of the call.
class StuckOfferWatch {
  StuckOfferWatch({
    required this.pendingOffer,
    required this.signalLive,
    required this.escalate,
    this.grace = kStuckOfferGrace,
  });

  final Future<String?> Function() pendingOffer;
  final bool Function() signalLive;
  final void Function() escalate;
  final Duration grace;

  Timer? _timer;

  /// Escalates when the offer out now is still the one out after [grace].
  Future<void> watch() async {
    cancel();
    final before = await pendingOffer();
    if (before == null) return;
    _timer = Timer(grace, () async {
      _timer = null;
      // A dead signal connection means another reconnect is already under way.
      if (!signalLive()) return;
      if (await pendingOffer() == before && signalLive()) escalate();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
