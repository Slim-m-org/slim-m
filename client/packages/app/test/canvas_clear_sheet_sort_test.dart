// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the scoped clear sheet sorts authors alphabetically by name.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_sheet.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('scoped clear sheet displays authors sorted alphabetically', (
    tester,
  ) async {
    const userZ = api.UserProfile(
      id: 'z_id',
      username: 'zack',
      displayName: 'Zack',
      createdAt: 0,
    );
    const userA = api.UserProfile(
      id: 'a_id',
      username: 'alice',
      displayName: 'Alice',
      createdAt: 0,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProfileProvider('z_id').overrideWith((ref) async => userZ),
          userProfileProvider('a_id').overrideWith((ref) async => userA),
          batchProfilesControllerProvider.overrideWith(
            (ref) => _StaticProfiles({'z_id': userZ, 'a_id': userA}),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => requestScopedCanvasClear(
                  context,
                  CanvasScopedClear(
                    clear: (_) async {},
                    authorIds: () => {'z_id', 'a_id'},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final aliceFinder = find.widgetWithText(AppListRow, 'Alice');
    final zackFinder = find.widgetWithText(AppListRow, 'Zack');
    expect(aliceFinder, findsOneWidget);
    expect(zackFinder, findsOneWidget);

    final aliceY = tester.getTopLeft(aliceFinder).dy;
    final zackY = tester.getTopLeft(zackFinder).dy;
    expect(aliceY, lessThan(zackY), reason: 'Alice must precede Zack');
  });
}

class _StaticProfiles extends StateNotifier<Map<String, api.UserProfile?>>
    implements BatchProfilesController {
  _StaticProfiles(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
