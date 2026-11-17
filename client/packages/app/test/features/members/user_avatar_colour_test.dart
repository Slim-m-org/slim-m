// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One colour per person: an initials disc is a shade of the person's profile
/// colour, found from their profile or handed over by a caller that holds it,
/// and never grey when the profile is not to hand.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/members/widgets/profile_colour.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = TokenPair(
  userId: 'u-me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

UserProfile _profile(String id, {int? colour, int? rgb}) => UserProfile(
  id: id,
  username: id,
  displayName: 'Dana Scully',
  createdAt: 0,
  profileColor: colour,
  profileColorRgb: rgb,
);

Future<AppAvatar> _avatar(
  WidgetTester tester,
  Widget avatar, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: avatar),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return tester.widget<AppAvatar>(
    find.byWidgetPredicate((widget) => widget is AppAvatar),
  );
}

void main() {
  testWidgets('another person\'s preset reaches the disc from their profile', (
    tester,
  ) async {
    final avatar = await _avatar(
      tester,
      const UserAvatar(name: 'Dana Scully', userId: 'u-dana'),
      overrides: [
        userProfileProvider.overrideWith(
          (ref, id) async => _profile(id, colour: 3),
        ),
      ],
    );

    expect(avatar.tintColor, AppCanvasColors.cursors[3]);
    expect(find.text('DS'), findsOneWidget);
  });

  testWidgets('a custom colour wins over the preset', (tester) async {
    final avatar = await _avatar(
      tester,
      const UserAvatar(name: 'Dana Scully', userId: 'u-dana'),
      overrides: [
        userProfileProvider.overrideWith(
          (ref, id) async => _profile(id, colour: 3, rgb: 0x112233),
        ),
      ],
    );

    expect(avatar.tintColor, const Color(0xFF112233));
  });

  testWidgets('your own avatar takes your colour from your own profile', (
    tester,
  ) async {
    final avatar = await _avatar(
      tester,
      const UserAvatar(name: 'Me', userId: 'u-me'),
      overrides: [
        meProvider.overrideWith(
          (ref) async => const Me(
            id: 'u-me',
            username: 'me',
            displayName: 'Me',
            createdAt: 0,
            permissions: 0,
            profileColor: 4,
          ),
        ),
      ],
    );

    expect(avatar.tintColor, AppCanvasColors.cursors[4]);
  });

  testWidgets('a known avatar takes the colour its caller holds', (
    tester,
  ) async {
    final avatar = await _avatar(
      tester,
      UserAvatar.known(
        name: 'Dana Scully',
        userId: 'u-dana',
        avatarUpdatedAt: null,
        profileColour: profileColourOfUser(_profile('u-dana', colour: 1)),
      ),
    );

    expect(avatar.tintColor, AppCanvasColors.cursors[1]);
  });

  testWidgets('with no profile to hand the disc takes the id\'s preset', (
    tester,
  ) async {
    final avatar = await _avatar(
      tester,
      const UserAvatar.known(
        name: 'Dana Scully',
        userId: 'u-dana',
        avatarUpdatedAt: null,
      ),
    );

    expect(avatar.tintColor, defaultProfileColour('u-dana'));
  });

  testWidgets('a square avatar is never handed a colour', (tester) async {
    final avatar = await _avatar(
      tester,
      const UserAvatar.known(
        name: 'Build Bot',
        userId: 'u-bot',
        avatarUpdatedAt: null,
        shape: AppAvatarShape.square,
      ),
    );

    expect(avatar.tintColor, isNull);
  });

  test('the fallback is the preset the server would give that id', () {
    const id = '0192f3c4-5b6a-7c8d-9e0f-1a2b3c4d5eab';
    expect(defaultProfileColour(id), AppCanvasColors.cursors[0xab % 6]);
    expect(
      AppCanvasColors.cursors,
      contains(defaultProfileColour('not-a-uuid')),
    );
  });
}
