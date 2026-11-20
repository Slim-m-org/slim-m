// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A file that could not be read leaves its error on the Soundboard pane only
/// while the pane is open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_intake.dart';
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import 'soundboard_harness.dart';

void main() {
  testWidgets('an intake error does not come back when the pane reopens', (
    tester,
  ) async {
    final wire = SoundboardWire();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'user-me',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        mockApiOverride(wire.handle),
        soundClipPickerProvider.overrideWithValue(
          () async => throw StateError('no picker'),
        ),
      ],
    );
    addTearDown(container.dispose);
    Future<void> mount(Widget home) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: home,
          ),
        ),
      );
      await pumpFrames(tester);
    }

    await mount(const SoundboardScreen());
    await tester.tap(soundboardCreateButton);
    await pumpFrames(tester);
    expect(find.text('Could not open the file picker.'), findsOneWidget);

    await mount(const SizedBox());
    await mount(const SoundboardScreen());

    expect(find.text('Could not open the file picker.'), findsNothing);
  });
}
