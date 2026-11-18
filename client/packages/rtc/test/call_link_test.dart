// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/audio_stats.dart';
import 'package:slimm_rtc/src/call_link.dart';
import 'package:slimm_rtc/src/call_stats.dart';

StatsEntry _pair(String id, double rtt, String local, String remote) =>
    StatsEntry(
      type: 'candidate-pair',
      id: id,
      values: {
        'state': 'succeeded',
        'currentRoundTripTime': rtt,
        'localCandidateId': local,
        'remoteCandidateId': remote,
      },
    );

StatsEntry _candidate(String id, String type, String protocol) => StatsEntry(
      type: id.startsWith('l') ? 'local-candidate' : 'remote-candidate',
      id: id,
      values: {'candidateType': type, 'protocol': protocol},
    );

/// A LAN host pair and a relayed pair have both succeeded; the transport uses the relay.
List<StatsEntry> _twoSucceeded() => [
      _pair('lan', 0.001, 'l-host', 'r-host'),
      _pair('turn', 0.040, 'l-relay', 'r-host'),
      _candidate('l-host', 'host', 'udp'),
      _candidate('l-relay', 'relay', 'tcp'),
      _candidate('r-host', 'host', 'udp'),
      const StatsEntry(
        type: 'transport',
        id: 't',
        values: {'selectedCandidatePairId': 'turn'},
      ),
    ];

void main() {
  group('the transport path', () {
    test(
        'describes the pair the transport selected, not the first that succeeded',
        () {
      final path = parseTransportStats(_twoSucceeded())!;
      expect(path.rttMs, closeTo(40, 0.001));
      expect(path.localType, 'relay');
      expect(path.protocol, 'tcp');
      expect(mediaRouteOf(path), MediaRoute.relayed);
    });

    test('agrees with the round trip the header shows', () {
      final entries = _twoSucceeded();
      expect(candidatePairRttMs(entries), parseTransportStats(entries)!.rttMs);
    });

    test('names direct UDP and the TCP fallback apart', () {
      const udp = TransportStats(localType: 'host', protocol: 'udp');
      const tcp = TransportStats(localType: 'srflx', protocol: 'tcp');
      expect(mediaRouteOf(udp), MediaRoute.direct);
      expect(mediaRouteOf(tcp), MediaRoute.directTcp);
      expect(mediaRouteOf(const TransportStats()), isNull);
    });
  });

  group('SignalPulse', () {
    test('counts silence from the last pong the SDK counted', () {
      var now = DateTime(2026, 11, 18, 20);
      final pulse = SignalPulse(clock: () => now);
      expect(
        pulse.observe(pings: 0, rttMs: 0),
        (rttMs: null, silence: null, heardAt: null),
      );
      final first = now;
      expect(
        pulse.observe(pings: 1, rttMs: 42),
        (rttMs: 42, silence: Duration.zero, heardAt: first),
      );
      now = now.add(const Duration(seconds: 5));
      final second = now;
      expect(
        pulse.observe(pings: 2, rttMs: 44),
        (rttMs: 44, silence: Duration.zero, heardAt: second),
      );
      now = now.add(const Duration(seconds: 12));
      expect(
        pulse.observe(pings: 2, rttMs: 44),
        (rttMs: 44, silence: const Duration(seconds: 12), heardAt: second),
      );
    });
  });
}
