// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A version the launcher rolled back from is not offered again, by the
/// Settings update rows or by the poll behind the title-bar menu and the rail
/// badge, while a newer release still is. Offering it would put an Install
/// control on a version that is never installed.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/update_status_rows.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

http.Client _releases(List<String> versions) => MockClient(
  (_) async => http.Response(
    jsonEncode([
      for (final v in versions)
        {
          'tag_name': 'client-v$v',
          'html_url': 'https://example.test/$v',
          'draft': false,
          'prerelease': false,
          'assets': [
            {'name': 'manifest.json'},
            {'name': 'manifest.json.sig'},
          ],
        },
    ]),
    200,
  ),
);

Future<ProviderContainer> _pumpRows(
  WidgetTester tester, {
  required List<String> published,
  required String failed,
}) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'slim-m',
            packageName: 'slim-m',
            version: '0.88.0',
            buildNumber: '1',
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return UpdateStatusRows(
                shouldRun: () => true,
                check: ({client, required currentVersion, format}) =>
                    checkForClientUpdate(
                      currentVersion: currentVersion,
                      client: _releases(published),
                      format: InstallFormat.tarball,
                      failedVersion: failed,
                    ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Check for updates'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('the version rolled back from is not offered', (tester) async {
    final container = await _pumpRows(
      tester,
      published: ['0.88.0', '0.89.0'],
      failed: '0.89.0',
    );
    expect(container.read(inSessionUpdateProvider), isNull);
    expect(find.textContaining('is available'), findsNothing);
    expect(find.text('You are on the latest version.'), findsOneWidget);
  });

  testWidgets('a release newer than the failed one is still offered', (
    tester,
  ) async {
    final container = await _pumpRows(
      tester,
      published: ['0.88.0', '0.89.0', '0.90.0'],
      failed: '0.89.0',
    );
    expect(container.read(inSessionUpdateProvider)?.version, '0.90.0');
    expect(find.text('Version 0.90.0 is available.'), findsOneWidget);
  });

  test('the poll behind the menu and badge applies the same rule', () async {
    final offered = await checkForClientUpdate(
      currentVersion: '0.88.0',
      client: _releases(['0.89.0']),
      format: InstallFormat.tarball,
      failedVersion: '0.89.0',
    );
    expect(offered, isNull);
  });
}
