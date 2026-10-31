// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/providers/windows_adopt.dart';
import 'package:slimm_app/src/widgets/windows_install_offer.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host({required bool available, WindowsAdoptAction? action}) =>
    ProviderScope(
      overrides: [
        windowsAdoptAvailableProvider.overrideWithValue(available),
        if (action != null)
          windowsAdoptActionProvider.overrideWithValue(action),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: WindowsInstallOffer()),
      ),
    );

void main() {
  testWidgets('is absent inside the layout and on other platforms', (
    tester,
  ) async {
    await tester.pumpWidget(_host(available: false));

    expect(find.text('Install for automatic updates'), findsNothing);
    expect(find.text('Automatic updates are off'), findsNothing);
  });

  testWidgets('offers the install outside the layout and runs it', (
    tester,
  ) async {
    var runs = 0;
    await tester.pumpWidget(_host(available: true, action: () async => runs++));

    expect(find.text('Automatic updates are off'), findsOneWidget);
    await tester.tap(find.text('Install for automatic updates'));
    await tester.pump();

    expect(runs, 1);
  });

  testWidgets('a failure shows inline and the offer stays', (tester) async {
    await tester.pumpWidget(
      _host(
        available: true,
        action: () async => throw const SelfUpdateFailure(
          SelfUpdateFailureKind.installFailed,
          'slim-m could not be installed for automatic updates.',
        ),
      ),
    );

    await tester.tap(find.text('Install for automatic updates'));
    await tester.pump();

    expect(
      find.text('slim-m could not be installed for automatic updates.'),
      findsOneWidget,
    );
    expect(find.text('Install for automatic updates'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
