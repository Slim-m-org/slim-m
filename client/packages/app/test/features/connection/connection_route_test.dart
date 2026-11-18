// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The connection report's legs, and when the route deserves a word.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/connection/connection_route.dart';
import 'package:slimm_rtc/rtc.dart';

final _now = DateTime(2026, 11, 18, 20, 17);

ConnectionReport _report({
  bool direct = false,
  String? apiColo = 'IAD',
  int apiMs = 80,
  String? signalColo = 'IAD',
  CallLink? call = const CallLink(
    mediaRttMs: 4,
    media: MediaRoute.direct,
    signalRttMs: 90,
  ),
}) => connectionReportOf(
  direct: direct,
  responded: true,
  apiColo: apiColo,
  apiRoundTrip: Duration(milliseconds: apiMs),
  apiMeasuredAt: _now,
  serverTrace: EdgeTrace(colo: apiColo ?? 'IAD', country: 'US'),
  signalTrace: signalColo == null
      ? null
      : EdgeTrace(colo: signalColo, country: 'US'),
  call: call,
  now: _now,
);

void main() {
  group('the legs', () {
    test('name the data centre city and each round trip', () {
      final legs = connectionLegs(_report(apiColo: 'GRU', signalColo: 'GRU'));
      expect(
        [for (final l in legs) '${l.label}: ${l.value}'],
        [
          'Server: Cloudflare São Paulo, 80 ms',
          'Call signalling: Cloudflare São Paulo, 90 ms',
          'Call audio: Direct, 4 ms',
        ],
      );
    });

    test(
      'the owner on his own network: the server is local, signalling still crosses Cloudflare',
      () {
        final legs = connectionLegs(
          _report(direct: true, apiColo: null, apiMs: 1),
        );
        expect(legs[0].value, 'Your local network, 1 ms');
        expect(legs[1].value, 'Cloudflare Ashburn, 90 ms');
      },
    );

    test('out of a call the call legs say so', () {
      final legs = connectionLegs(_report(call: null));
      expect(legs[1].value, 'Not in a call');
      expect(legs[2].value, 'Not in a call');
    });

    test('a relayed or TCP path is named in plain words', () {
      String audio(MediaRoute route) => connectionLegs(
        _report(call: CallLink(mediaRttMs: 40, media: route)),
      )[2].value;
      expect(audio(MediaRoute.relayed), 'Relayed through the server, 40 ms');
      expect(audio(MediaRoute.directTcp), 'Direct (TCP fallback), 40 ms');
    });

    test('a signalling socket that stopped answering says so in amber', () {
      final leg = connectionLegs(
        _report(
          call: const CallLink(
            mediaRttMs: 4,
            signalRttMs: 90,
            signalSilence: Duration(seconds: 13),
          ),
        ),
      )[1];
      expect(leg.value, 'Not answering');
      expect(leg.warn, isTrue);
    });

    test('an unknown data centre shows its code', () {
      expect(coloCity('ZZZ'), 'ZZZ');
    });
  });

  group('the route concern', () {
    test('a data centre outside the device country is far', () {
      final concern = routeConcernOf(_report(signalColo: 'GRU'));
      expect(concern?.farCity, 'São Paulo');
      expect(concern!.message, contains('through São Paulo'));
    });

    test('a nearby data centre in the same country is not', () {
      expect(
        routeConcernOf(_report(apiColo: 'EWR', signalColo: 'IAD')),
        isNull,
      );
    });

    test('a slow Cloudflare leg beside quick call audio is slow', () {
      expect(
        routeConcernOf(_report(apiMs: kSlowRouteMs)),
        const RouteConcern(),
      );
      expect(routeConcernOf(_report(apiMs: kSlowRouteMs - 1)), isNull);
    });

    test('slow everywhere is the network, not the route', () {
      final report = _report(
        apiMs: 400,
        call: const CallLink(mediaRttMs: 300, signalRttMs: 400),
      );
      expect(routeConcernOf(report), isNull);
    });

    test('the local network is never slow over Cloudflare', () {
      expect(
        routeConcernOf(
          _report(direct: true, apiColo: null, apiMs: 400, signalColo: null),
        ),
        isNull,
      );
    });
  });

  group('RouteConcernGate', () {
    test('shows after two readings and clears after three clean ones', () {
      final gate = RouteConcernGate();
      const far = RouteConcern(farCity: 'São Paulo');
      expect(gate.update(far), isNull);
      expect(gate.update(far), far);
      expect(gate.update(null), far);
      expect(gate.update(null), far);
      expect(gate.update(null), isNull);
    });

    test('one flip does not flicker it', () {
      final gate = RouteConcernGate();
      const far = RouteConcern(farCity: 'São Paulo');
      expect(gate.update(far), isNull);
      expect(gate.update(null), isNull);
      expect(gate.update(far), isNull);
    });
  });

  test('the checked line counts up from the last reading', () {
    expect(checkedLine(null, _now), isNull);
    expect(checkedLine(_now, _now), 'Checked just now');
    expect(
      checkedLine(_now, _now.add(const Duration(seconds: 12))),
      'Checked 12 s ago',
    );
  });
}
