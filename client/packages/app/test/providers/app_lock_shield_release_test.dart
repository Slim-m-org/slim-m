// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The privacy shield is released on the frame after a resume, and never by a
/// controller that was disposed before that frame came.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';

AppLockHost _host(List<String> released) => AppLockHost(
  enabled: () => false,
  signedIn: () => false,
  signedInChanges: const Stream<bool>.empty(),
  channel: () => throw UnimplementedError(),
  disable: () async {},
  releaseShield: () async => released.add('released'),
);

void main() {
  testWidgets('a resume releases the shield on the next frame', (tester) async {
    final released = <String>[];
    final controller = AppLockController(_host(released));
    addTearDown(controller.dispose);

    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(released, isEmpty);
    await tester.pump();

    expect(released, ['released']);
  });

  testWidgets(
    'a controller disposed before that frame never touches its host',
    (tester) async {
      final released = <String>[];
      AppLockController(_host(released))
        ..didChangeAppLifecycleState(AppLifecycleState.resumed)
        ..dispose();

      await tester.pump();

      expect(released, isEmpty);
    },
  );
}
