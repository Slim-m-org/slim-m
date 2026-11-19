// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live report: the server leg from one timed request, and the call's host traced again after a repair.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/connection/connection_route.dart';
import 'package:slimm_app/src/features/connection/providers/connection_report.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/voice_controller_harness.dart';

/// Answers the timed ping through [apiColo] and the call host's trace from
/// [signalColo], with no Cloudflare when that is null; a trace fails while [traceFails].
class _Edge {
  String apiColo = 'EWR';
  String? signalColo = 'EWR';
  bool traceFails = false;
  int traces = 0;

  http.Client client() => MockClient((request) async {
    if (request.url.path == '/cdn-cgi/trace') {
      traces++;
      if (traceFails) throw http.ClientException('Connection reset by peer');
      final colo = signalColo;
      if (colo == null) return http.Response('Not found', 404);
      return http.Response('colo=$colo\nloc=US\nip=203.0.113.9\n', 200);
    }
    if (request.url.path == '/diagnostics/ping') {
      return http.Response(
        '{}',
        200,
        headers: {
          'content-type': 'application/json',
          'cf-ray': '8f1c2d3e4f5a6b7c-$apiColo',
        },
      );
    }
    return http.Response('{}', 404);
  });
}

void main() {
  late VoiceHarness harness;
  late FakeSession session;
  late _Edge edge;

  setUp(() {
    harness = VoiceHarness();
    session = FakeSession();
    edge = _Edge();
    harness.controllerWith(session, edge.client());
  });
  tearDown(() => harness.dispose());

  ConnectionReport report() =>
      harness.container.read(connectionStatusProvider).report;

  Future<void> inCall() async {
    harness.container.listen(connectionStatusProvider, (_, _) {});
    session.health.signalUrl = Uri.parse('wss://livekit.example.org');
    session.health.noteLink(
      CallLink(mediaRttMs: 4, signalRttMs: 40, at: DateTime.now()),
    );
    await pumpEventQueue();
  }

  test('the server leg names the data centre its own timed request came '
      'through', () async {
    await inCall();
    expect(report().server, ServerRoute.cloudflare);
    expect(report().serverColo, 'EWR');
    expect(report().serverRttMs, isNotNull);
  });

  test('a repaired signalling socket has its data centre read again', () async {
    await inCall();
    expect(report().signalColo, 'EWR');
    edge.signalColo = 'GRU';
    session.health.reconnect.started(ReconnectKind.resume);
    await pumpEventQueue();
    expect(report().signalColo, 'EWR');
    session.health.reconnect.ended('resumed');
    await pumpEventQueue();
    expect(report().signalColo, 'GRU');
  });

  Future<void> repair() async {
    session.health.reconnect.started(ReconnectKind.resume);
    await pumpEventQueue();
    session.health.reconnect.ended('resumed');
    await pumpEventQueue();
  }

  test(
    'a trace that fails after a repair keeps the data centre it had',
    () async {
      await inCall();
      edge.traceFails = true;
      await repair();
      expect(edge.traces, greaterThan(1));
      expect(report().signalColo, 'EWR');
    },
  );

  test('signalling that went over his own network reads as local, and a '
      'reconnect that went public reads as Cloudflare again', () async {
    harness.container.listen(connectionStatusProvider, (_, _) {});
    session.health.signalUrl = Uri.parse('wss://livekit.example.org');
    session.health.noteLink(
      CallLink(
        mediaRttMs: 4,
        signalRttMs: 2,
        signalDirect: true,
        at: DateTime.now(),
      ),
    );
    await pumpEventQueue();
    expect(report().signalDirect, isTrue);
    expect(connectionLegs(report())[1].value, 'Your local network, 2\u00a0ms');

    session.health.noteLink(
      CallLink(mediaRttMs: 4, signalRttMs: 40, at: DateTime.now()),
    );
    await pumpEventQueue();
    expect(connectionLegs(report())[1].value, 'Cloudflare Newark, 40\u00a0ms');
  });

  test(
    'a host no Cloudflare answers for after a repair reads as none',
    () async {
      await inCall();
      edge.signalColo = null;
      await repair();
      expect(report().signalColo, isNull);
    },
  );
}
