// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A join leaves one debug-log line of stage timings and asks for its own token.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/voice/providers/join_timings_provider.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();
  late List<http.Request> tokenRequests;

  tearDown(harness.dispose);

  setUp(() => tokenRequests = []);

  http.Client api() => voiceApi(
    onRequest: (request) {
      if (request.url.path.endsWith('/voice/token')) tokenRequests.add(request);
    },
  );

  test('the join logs its stages in the order it reached them', () async {
    final controller = harness.controllerWith(FakeSession(), api());

    await controller.join('channel-1');
    final timings = harness.container.read(joinTimingsProvider)..finish();

    final millis = timings.last!.millis;
    final order = [
      JoinStage.click,
      JoinStage.tokenRequested,
      JoinStage.tokenReceived,
    ];
    expect(millis.keys.toList(), order);
    final values = [for (final stage in order) millis[stage]!];
    expect([...values]..sort(), values);
    final logged = harness
        .log(controller)
        .where((e) => e.message.startsWith('Join timings'));
    expect(logged, hasLength(1));
    expect(logged.single.source, 'voice');
  });

  test('every join asks for its own token', () async {
    final controller = harness.controllerWith(FakeSession(), api());

    await controller.join('channel-1');

    expect(tokenRequests, hasLength(1));
    await controller.leave();
    await controller.join('channel-1');
    expect(tokenRequests, hasLength(2));
  });
}
