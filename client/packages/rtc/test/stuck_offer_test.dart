// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/src/stuck_offer.dart';

class _OfferingConnection implements rtc.RTCPeerConnection {
  rtc.RTCSignalingState state =
      rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer;
  String sdp = _offer;

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async => state;

  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() async =>
      rtc.RTCSessionDescription(sdp, 'offer');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _offer = 'v=0\r\n'
    'o=- 6678563200139743666 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';

void main() {
  const grace = Duration(seconds: 5);

  group('which offer is out', () {
    test('a connection with no offer out has none pending', () async {
      final pc = _OfferingConnection()
        ..state = rtc.RTCSignalingState.RTCSignalingStateStable;
      expect(await pendingOffer(pc), isNull);
      expect(await pendingOffer(null), isNull);
    });

    test('candidates gathered into the pending offer leave it the same offer',
        () async {
      final pc = _OfferingConnection();
      final before = await pendingOffer(pc);
      pc.sdp =
          '${_offer}a=candidate:1 1 udp 2113937151 10.0.0.2 51000 typ host\r\n';

      expect(before, isNotNull);
      expect(await pendingOffer(pc), before);
    });

    test('the next offer of the same session is a different one', () async {
      final pc = _OfferingConnection();
      final before = await pendingOffer(pc);
      pc.sdp = _offer.replaceFirst('743666 2 IN', '743666 3 IN');

      expect(await pendingOffer(pc), isNot(before));
    });
  });

  ({StuckOfferWatch watch, List<String> escalations}) build({
    required String? Function() offer,
    bool Function()? live,
  }) {
    final escalations = <String>[];
    final watch = StuckOfferWatch(
      pendingOffer: () async => offer(),
      signalLive: live ?? () => true,
      escalate: () => escalations.add('restart'),
      grace: grace,
    );
    return (watch: watch, escalations: escalations);
  }

  test('the same offer still unanswered after the grace is escalated', () {
    fakeAsync((async) {
      final built = build(offer: () => 'offer-1');
      unawaited(built.watch.watch());
      async.elapse(grace - const Duration(milliseconds: 1));
      expect(built.escalations, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(built.escalations, ['restart']);
    });
  });

  test('an offer answered within the grace is left alone', () {
    fakeAsync((async) {
      String? offer = 'ice-restart';
      final built = build(offer: () => offer);
      unawaited(built.watch.watch());
      async.elapse(const Duration(seconds: 1));
      offer = null;
      async.elapse(grace);
      expect(built.escalations, isEmpty);
    });
  });

  test('a different offer out at the end of the grace is not the stuck one',
      () {
    fakeAsync((async) {
      var offer = 'ice-restart';
      final built = build(offer: () => offer);
      unawaited(built.watch.watch());
      async.elapse(const Duration(seconds: 4));
      offer = 'camera';
      async.elapse(grace);
      expect(built.escalations, isEmpty);
    });
  });

  test('no offer out after the resume means nothing to watch', () {
    fakeAsync((async) {
      final built = build(offer: () => null);
      unawaited(built.watch.watch());
      async.elapse(grace * 2);
      expect(built.escalations, isEmpty);
    });
  });

  test('a signal connection that dropped again leaves it to that reconnect',
      () {
    fakeAsync((async) {
      var live = true;
      final built = build(offer: () => 'offer-1', live: () => live);
      unawaited(built.watch.watch());
      live = false;
      async.elapse(grace * 2);
      expect(built.escalations, isEmpty);
    });
  });

  test('cancelling stops a pending check', () {
    fakeAsync((async) {
      final built = build(offer: () => 'offer-1');
      unawaited(built.watch.watch());
      async.flushMicrotasks();
      built.watch.cancel();
      async.elapse(grace * 2);
      expect(built.escalations, isEmpty);
    });
  });
}
