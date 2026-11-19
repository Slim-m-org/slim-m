// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host knows which account is in a call the moment that changes, with
/// no frame drawn: a window hidden to the tray draws none.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_root.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';

import 'account_host_harness.dart';

const _first = 'https://first.example';
const _second = 'https://second.example';

void main() {
  late AccountHarness h;

  Future<void> boot(WidgetTester tester) async {
    h = AccountHarness();
    await tester.runAsync(() async {
      await h.seed(_first, user: 'ann', active: true);
      await h.seed(_second, user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    await tester.pumpWidget(
      AccountRoot(host: h.host, app: const SizedBox.shrink()),
    );
    await tester.pump();
  }

  void setCall(String origin, VoiceFlags flags) =>
      h.host
              .runtimeFor(origin)!
              .container
              .read(testCallProvider.notifier)
              .state =
          flags;

  testWidgets('a call that starts and ends in an account out of view is '
      'known before the next frame', (tester) async {
    await boot(tester);

    setCall(_second, connectedCall);
    expect(h.host.callRuntime?.account?.origin, _second);
    expect(h.host.callElsewhere?.account?.origin, _second);

    setCall(_second, const VoiceFlags());
    expect(h.host.callRuntime, isNull);
    expect(h.host.callElsewhere, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a call joined out of view ends the one on screen before the '
      'next frame', (tester) async {
    await boot(tester);
    setCall(_first, connectedCall);
    expect(h.host.callRuntime?.account?.origin, _first);

    setCall(_second, connectedCall);
    await tester.runAsync(pumpEventQueueTimes);

    expect(h.host.runtimeFor(_first)!.inCall, isFalse);
    expect(h.host.callRuntime?.account?.origin, _second);
    await tester.pumpWidget(const SizedBox());
  });
}
