// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The timeout watcher keeps asking until the server stops reporting a timeout,
/// so a device clock that runs ahead of the server's does not strand the
/// stripped permissions.
library;

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  late Duration floor;
  setUp(() {
    floor = timeoutRecheckFloor;
    timeoutRecheckFloor = const Duration(milliseconds: 20);
  });
  tearDown(() => timeoutRecheckFloor = floor);

  test('a server that still reports the timeout is asked again', () async {
    var answers = 0;
    final until = clock.now().millisecondsSinceEpoch + 30;
    final container = ProviderContainer(
      overrides: [
        meProvider.overrideWith((ref) async {
          answers++;
          return api.Me(
            id: 'me',
            username: 'me',
            displayName: 'Me',
            createdAt: 0,
            permissions: 0,
            timedOutUntil: answers < 4 ? until : null,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(meProvider, (_, _) {});
    container.listen(timeoutExpiryWatcherProvider, (_, _) {});

    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(answers, 4, reason: 'it kept asking until the timeout was gone');
    expect(container.read(meProvider).valueOrNull?.timedOutUntil, isNull);
  });
}
