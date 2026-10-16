// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The empty apps launcher used to render while `appLaunchProvider` was
/// still resolving too, since `.valueOrNull ?? []` cannot tell "loading"
/// from "confirmed empty".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/app_launch.dart';
import 'package:slimm_app/src/widgets/app_launcher_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

// The non-admin copy: myPermissionsProvider defaults to 0 with no override.
const _emptyCopy =
    'No apps installed. Ask an admin to install one from '
    'Modules.';

Future<void> _open(WidgetTester tester, Future<List<api.App>> future) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appLaunchProvider.overrideWith((ref) => future)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showAppLauncherSheet(context, ref, 'c1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // Not pumpAndSettle: the spinner this proves is showing animates forever.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('shows a spinner, not the empty copy, while still resolving', (
    tester,
  ) async {
    final completer = Completer<List<api.App>>();
    await _open(tester, completer.future);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(_emptyCopy), findsNothing);

    completer.complete(const <api.App>[]);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(_emptyCopy), findsOneWidget);
  });

  testWidgets('a confirmed empty list still reads as empty, not loading', (
    tester,
  ) async {
    await _open(tester, Future.value(const <api.App>[]));

    expect(find.text(_emptyCopy), findsOneWidget);
  });
}
