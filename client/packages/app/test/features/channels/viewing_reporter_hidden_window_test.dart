// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A window closed to the tray stops telling the server its channel is being
/// read at once, not at the next refresh: a hidden window draws no frame.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/viewing_reporter.dart';

import '../../support/fake_sync.dart';

class _RecordingSync extends NoopSyncController {
  _RecordingSync(super.ref);

  final viewed = <Set<String>>[];

  @override
  void notifyViewing(Iterable<String> channelIds, {bool active = false}) =>
      viewed.add(channelIds.toSet());
}

void main() {
  testWidgets('closing a focused window to the tray reports nothing open', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    late _RecordingSync sync;
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(
          (ref) => sync = _RecordingSync(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    container.read(viewingReporterProvider);
    container.read(mountedChannelsProvider).register('c1');
    await tester.pump();
    expect(sync.viewed.last, {'c1'});

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.idle();

    expect(sync.viewed.last, isEmpty);
  });
}
