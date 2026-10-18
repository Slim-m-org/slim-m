// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A profile that says it has no avatar is never asked for one.
///
/// `avatar_updated_at` is null exactly when no avatar was uploaded, so
/// requesting the picture anyway is a guaranteed 404 per member.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

Future<List<String>> _pumpAvatar(WidgetTester tester, int? updatedAt) async {
  final requested = <String>[];
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        requested.add(request.url.path);
        return http.Response('', 404);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: UserAvatar.known(
            name: 'Dana',
            userId: 'u2',
            avatarUpdatedAt: updatedAt,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return requested;
}

void main() {
  testWidgets('no avatar timestamp means no request, only initials', (
    tester,
  ) async {
    final requested = await _pumpAvatar(tester, null);

    expect(requested, isEmpty);
    expect(find.text(initialsFor('Dana')), findsOneWidget);
  });

  testWidgets('an avatar timestamp fetches that user\'s picture', (
    tester,
  ) async {
    final requested = await _pumpAvatar(tester, 1700000000000);

    expect(requested, ['/users/u2/avatar']);
  });
}
