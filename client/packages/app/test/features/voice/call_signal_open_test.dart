// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A native call's signalling asks the signed-in server's own-network route
/// first, with LiveKit's URL and headers as they are, and the session a call
/// controller builds for itself is handed that way.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_api/src/direct_route.dart';
import 'package:slimm_app/src/features/voice/providers/join_timings_provider.dart';
import 'package:slimm_app/src/features/voice/providers/voice_sfu_connect.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/dead_voice_session.dart';

/// Records each sibling socket asked for and declines it, without naming the socket type the app never imports.
class _SiblingRoute implements DirectRoute {
  final asked = <(Uri, Map<String, String>?)>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #connectSiblingDirect) return null;
    asked.add((
      invocation.positionalArguments.single as Uri,
      invocation.namedArguments[#headers] as Map<String, String>?,
    ));
    return Future<Null>.value();
  }
}

final _opener = Provider(callSignalOpen);

void main() {
  late _SiblingRoute route;
  late ProviderContainer container;
  final url = Uri.parse('wss://livekit.slimm.test/rtc');

  setUp(() {
    route = _SiblingRoute();
    container = ProviderContainer(
      overrides: [
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('https://slimm.test'),
            httpClient: MockClient((_) async => http.Response('{}', 404)),
            directRoute: route,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  test('the call signalling goes to the active server\'s route', () async {
    final open = container.read(_opener)!;
    expect(await open(url, {'Authorization': 'Bearer t'}), isNull);

    final (asked, headers) = route.asked.single;
    expect(asked, url);
    expect(headers, {'Authorization': 'Bearer t'});
  });

  test('the session a controller builds for itself gets that opener and the '
      'shared join timings', () async {
    SignalSocketOpen? given;
    JoinTimings? timings;
    final made = Provider(
      (ref) => callSession(
        ref,
        build: ({joinTimings, signalOpen, audioLog}) {
          given = signalOpen;
          timings = joinTimings;
          return DeadVoiceSession();
        },
      ),
    );

    container.read(made);

    expect(timings, same(container.read(joinTimingsProvider)));
    expect(await given!(url, null), isNull);
    expect(route.asked.single.$1, url);
  });
}
