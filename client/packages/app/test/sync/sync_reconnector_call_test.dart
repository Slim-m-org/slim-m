// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone in the background still reconnects while it is in a call.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/sync/providers/reconnect_backoff.dart';
import 'package:slimm_app/src/sync/providers/sync_reconnector.dart';
import 'package:slimm_app/src/sync/providers/sync_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int retriesAfterDrop({required bool inCall}) {
    var starts = 0;
    fakeAsync((async) {
      final container = ProviderContainer(
        overrides: [
          mobileLifecycleHostProvider.overrideWithValue(true),
          appLifecycleProvider.overrideWith(
            (ref) => _FixedLifecycle(AppLifecycleState.paused),
          ),
        ],
      );
      final reconnector = container.read(
        Provider(
          (ref) => SyncReconnector(
            ref: ref,
            backoff: ReconnectBackoff(step: const Duration(milliseconds: 1)),
            start: () async => starts++,
            isDisposed: () => false,
            wantsConnection: () => true,
            status: () => SyncStatus.offline,
            generation: () => 0,
            probe: () => null,
            failConnect: (_, _) {},
            inCall: () => inCall,
          ),
        ),
      );
      reconnector.scheduleRetry();
      async.elapse(const Duration(seconds: 5));
      container.dispose();
    });
    return starts;
  }

  test('a backgrounded phone in a call schedules the reconnect', () {
    expect(retriesAfterDrop(inCall: true), 1);
  });

  test('a backgrounded phone out of a call still waits for the foreground', () {
    expect(retriesAfterDrop(inCall: false), 0);
  });
}

class _FixedLifecycle extends AppLifecycleNotifier {
  _FixedLifecycle(AppLifecycleState initial)
    : super(mobile: true, windowEvents: const Stream.empty()) {
    state = initial;
  }
}
