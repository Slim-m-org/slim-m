// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `showAppSnackbar` raises the app's one toast, never a Material SnackBar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/widgets/app_snackbar.dart';
import 'package:slimm_app/src/widgets/toast_overlay.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('a message appears as a toast and no SnackBar is built', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppSnackbar(context, 'a message'),
                child: const Text('go'),
              ),
            ),
          ),
          builder: (context, child) => Stack(
            children: [
              child ?? const SizedBox.shrink(),
              const Positioned.fill(child: ToastOverlay()),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('a message'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SnackBar), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byWidgetPredicate((w) => w is Scaffold)),
    );
    expect(container.read(toastsProvider), hasLength(1));
    await tester.pump(ToastsController.defaultDuration);
  });
}
