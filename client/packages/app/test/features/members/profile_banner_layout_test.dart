// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member profile sheet and the Settings banner row, asserted from render
/// boxes: the name clears the banner, presence shows once, there is no banner
/// swatch beside the preview, the image is a tile in the colour row, and the
/// Picture title never meets its thumbnail.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_settings_section.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/features/members/widgets/profile_banner.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

const _profile = api.UserProfile(
  id: 'user-claude',
  username: 'Claude',
  displayName: 'Claude',
  createdAt: 1790000000000,
  roles: ['admin'],
  profileColor: 2,
);

api.Me _me({int? banner}) => api.Me(
  id: 'user-nick',
  username: 'nick',
  displayName: 'Nick',
  createdAt: 1790000000000,
  permissions: 0,
  profileColor: 0,
  avatarUpdatedAt: 1,
  bannerUpdatedAt: banner,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  for (final width in [390.0, 320.0]) {
    testWidgets('sheet at $width: name below banner, presence once', (
      tester,
    ) async {
      await _pump(
        tester,
        MemberProfileBody(profile: _profile, compact: true, onDone: () {}),
        width: width,
        overrides: [
          membersProvider.overrideWith((ref) async => [_profile]),
          presenceForProvider.overrideWith((ref, id) => AppPresence.away),
        ],
      );
      final banner = tester.getRect(find.byType(MemberProfileBanner));
      final avatar = tester.getRect(find.byType(UserAvatar));
      final name = tester.getRect(find.text('Claude').first);
      expect(avatar.top, lessThan(banner.bottom));
      expect(avatar.bottom, greaterThan(banner.bottom));
      expect(name.top, greaterThanOrEqualTo(avatar.bottom));
      expect(name.top, greaterThanOrEqualTo(banner.bottom));
      expect(find.byType(AppStatusDot), findsOneWidget);
      expect(find.text('Away'), findsOneWidget);
    });
  }

  for (final banner in [null, 1]) {
    testWidgets('settings banner row, image ${banner != null}', (tester) async {
      await _pump(
        tester,
        const AvatarSettingsSection(),
        overrides: [
          meProvider.overrideWith((ref) async => _me(banner: banner)),
        ],
      );
      expect(find.byKey(const Key('banner-settings-preview')), findsNothing);
      final image = tester.getRect(find.byKey(const Key('banner-image-tile')));
      final colour = tester.getRect(
        find.bySemanticsLabel('Profile colour: Pink'),
      );
      expect((image.center.dy - colour.center.dy).abs(), lessThan(1));
      expect(image.right, lessThanOrEqualTo(colour.left));
      final title = tester.getRect(find.text('Picture'));
      final thumb = tester.getRect(find.byType(UserAvatar).first);
      expect(title.left, greaterThanOrEqualTo(thumb.right));
    });
  }
}
