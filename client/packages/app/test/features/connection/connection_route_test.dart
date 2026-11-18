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
  DateTime? apiAt,
  String? signalColo = 'IAD',
  CallLink? call = const CallLink(
    mediaRttMs: 4,
    media: MediaRoute.direct,
    signalRttMs: 90,
  ),
}) => connectionReportOf(
  server: EdgeReading(
    colo: apiColo,
    direct: direct,
    roundTrip: Duration(milliseconds: apiMs),
    at: apiAt ?? _now,
  ),
  signalTrace: signalColo == null ? null : EdgeTrace(colo: signalColo),
  call: call,
);

/// A call sample at [at] whose signalling answer last renewed at [signalAt].
CallLink _sample(DateTime at, {required int signalMs, DateTime? signalAt}) =>
    CallLink(
      mediaRttMs: 20,
      media: MediaRoute.direct,
      signalRttMs: signalMs,
      signalAt: signalAt ?? at,
      at: at,
    );

void main() {
  group('the legs', () {
    test('name the data centre city and each round trip', () {
      final legs = connectionLegs(_report(apiColo: 'GRU', signalColo: 'GRU'));
      expect(
        [for (final l in legs) '${l.label}: ${l.value}'],
        [
          'Server: Cloudflare São Paulo, 80\u00a0ms',
          'Call signalling: Cloudflare São Paulo, 90\u00a0ms',
          'Call audio: Direct, 4\u00a0ms',
        ],
      );
    });

    test(
      'the owner on his own network: the server is local, signalling still crosses Cloudflare',
      () {
        final legs = connectionLegs(
          _report(direct: true, apiColo: null, apiMs: 1),
        );
        expect(legs[0].value, 'Your local network, 1\u00a0ms');
        expect(legs[1].value, 'Cloudflare Ashburn, 90\u00a0ms');
      },
    );

    test('a request answered through Cloudflare reads as Cloudflare even '
        'while the local route is on for others', () {
      final legs = connectionLegs(_report(direct: true, apiColo: 'EWR'));
      expect(legs[0].value, 'Cloudflare Newark, 80\u00a0ms');
    });

    test('out of a call the call legs say so', () {
      final legs = connectionLegs(_report(call: null));
      expect(legs[1].value, 'Not in a call');
      expect(legs[2].value, 'Not in a call');
    });

    test('a relayed or TCP path is named in plain words', () {
      String audio(MediaRoute route) => connectionLegs(
        _report(call: CallLink(mediaRttMs: 40, media: route)),
      )[2].value;
      expect(
        audio(MediaRoute.relayed),
        'Relayed through the server, 40\u00a0ms',
      );
      expect(audio(MediaRoute.directTcp), 'Direct (TCP fallback), 40\u00a0ms');
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
    test('a data centre abroad with a quick route raises nothing', () {
      expect(serverConcernOf(_report(apiColo: 'GRU')), isNull);
      expect(signalConcernOf(_report(signalColo: 'GRU')), isNull);
    });

    test('a slow Cloudflare leg beside quick call audio is slow', () {
      const quick = CallLink(mediaRttMs: 60, media: MediaRoute.direct);
      final slow = _report(apiColo: 'GRU', apiMs: kSlowRouteMs, call: quick);
      expect(serverConcernOf(slow), const RouteConcern(city: 'São Paulo'));
      expect(
        serverConcernOf(_report(apiMs: kSlowRouteMs - 1, call: quick)),
        isNull,
      );
    });

    test('a leg well past slower call audio is a detour', () {
      final report = _report(
        signalColo: 'GRU',
        call: const CallLink(mediaRttMs: 150, signalRttMs: 150 + kDetourMs),
      );
      expect(signalConcernOf(report)?.city, 'São Paulo');
    });

    test('slow everywhere is the network, not the route', () {
      final report = _report(
        apiMs: 400,
        call: const CallLink(mediaRttMs: 300, signalRttMs: 400),
      );
      expect(serverConcernOf(report), isNull);
      expect(signalConcernOf(report), isNull);
    });

    test('outside a call nothing is quick to compare with', () {
      expect(serverConcernOf(_report(apiMs: 600, call: null)), isNull);
    });

    test('the local network is never slow over Cloudflare', () {
      expect(
        serverConcernOf(_report(direct: true, apiColo: null, apiMs: 400)),
        isNull,
      );
    });
  });

  group('RouteConcernGate', () {
    test('shows after two readings and clears after three clean ones', () {
      final gate = RouteConcernGate();
      const slow = RouteConcern(city: 'São Paulo');
      expect(gate.update(slow), isNull);
      expect(gate.update(slow), slow);
      expect(gate.update(null), slow);
      expect(gate.update(null), slow);
      expect(gate.update(null), isNull);
    });

    test('one flip does not flicker it', () {
      final gate = RouteConcernGate();
      const slow = RouteConcern(city: 'São Paulo');
      expect(gate.update(slow), isNull);
      expect(gate.update(null), isNull);
      expect(gate.update(slow), isNull);
    });
  });

  group('RouteWatch', () {
    test('one slow answer read by many call samples counts once', () {
      final watch = RouteWatch();
      final heard = _now;
      for (var i = 0; i < 4; i++) {
        final at = _now.add(Duration(seconds: 5 * i));
        final report = _report(
          signalColo: 'GRU',
          call: _sample(at, signalMs: 400, signalAt: heard),
        );
        expect(watch.update(report, at), isNull);
      }
    });

    test('two slow answers in a row show it', () {
      final watch = RouteWatch();
      RouteConcern? at(int s) {
        final t = _now.add(Duration(seconds: s));
        return watch.update(
          _report(signalColo: 'GRU', call: _sample(t, signalMs: 400)),
          t,
        );
      }

      expect(at(0), isNull);
      expect(at(5)?.city, 'São Paulo');
    });

    test('a concern goes once its leg has not been measured for a while', () {
      final watch = RouteWatch();
      final first = _report(apiColo: 'GRU', apiMs: 400, apiAt: _now);
      final later = _now.add(const Duration(seconds: 5));
      watch.update(first, _now);
      final second = _report(apiColo: 'GRU', apiMs: 400, apiAt: later);
      expect(watch.update(second, later)?.city, 'São Paulo');
      expect(watch.update(second, later.add(kConcernFreshFor)), isNull);
    });

    test('ends with the call', () {
      final watch = RouteWatch();
      for (final s in [0, 5]) {
        final t = _now.add(Duration(seconds: s));
        watch.update(
          _report(signalColo: 'GRU', call: _sample(t, signalMs: 400)),
          t,
        );
      }
      expect(watch.update(_report(call: null), _now), isNull);
    });
  });

  group('the checked time', () {
    test('is the older of the server leg and the call sample', () {
      final sampled = _now.add(const Duration(seconds: 30));
      final report = _report(call: _sample(sampled, signalMs: 90));
      expect(report.checkedAt, _now);
    });

    test('a call sample that stopped is not fresh', () {
      final stalled = _now.subtract(const Duration(seconds: 40));
      final report = _report(call: _sample(stalled, signalMs: 90));
      expect(report.checkedAt, stalled);
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
