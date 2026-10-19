// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile banner: an image (or gif) when set, the profile colour when
/// not, paused with the window like every animation, and removable from the
/// Identity card.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/banner_bytes.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_settings_section.dart';
import 'package:slimm_app/src/features/members/widgets/profile_banner.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _gif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

Widget _scope(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

Map<String, dynamic> _me(int? bannerUpdatedAt) => {
  'id': 'self',
  'username': 'self',
  'display_name': 'Self',
  'created_at': 0,
  'permissions': 0,
  if (bannerUpdatedAt != null) 'banner_updated_at': bannerUpdatedAt,
};

void main() {
  testWidgets(
    'with no banner it draws the profile colour and fetches nothing',
    (tester) async {
      var fetched = false;
      final container = ProviderContainer(
        overrides: [
          bannerBytesProvider.overrideWith((ref, key) async {
            fetched = true;
            return Uint8List.fromList(_gif);
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _scope(
          container,
          const ProfileBanner(
            userId: 'u',
            bannerUpdatedAt: null,
            colour: Color(0xFF336699),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(fetched, isFalse);
      final fill = tester.widget<ColoredBox>(find.byType(ColoredBox).last);
      expect(fill.color, const Color(0xFF336699));
    },
  );

  testWidgets('a set banner draws the image, and a gif holds while unfocused', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        bannerBytesProvider.overrideWith(
          (ref, key) async => Uint8List.fromList(_gif),
        ),
      ],
    );
    addTearDown(container.dispose);
    final binding = TestWidgetsFlutterBinding.instance;
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );

    await tester.pumpWidget(
      _scope(
        container,
        const ProfileBanner(userId: 'u', bannerUpdatedAt: 5, colour: null),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    bool ticking() => tester
        .widget<TickerMode>(
          find
              .ancestor(
                of: find.byType(Image),
                matching: find.byType(TickerMode),
              )
              .first,
        )
        .enabled;
    expect(ticking(), isTrue);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();

    expect(ticking(), isFalse, reason: 'an unfocused window stops the gif');
  });

  testWidgets('the Identity card offers Remove only with a banner, and it '
      'deletes it', (tester) async {
    var banner = 5;
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/me/banner') {
            banner = 0;
            return http.Response('', 204);
          }
          if (request.url.path == '/me') {
            return http.Response(
              jsonEncode(_me(banner == 0 ? null : banner)),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 404);
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_scope(container, const AvatarSettingsSection()));
    await tester.pumpAndSettle();
    expect(find.text('Custom image'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Remove profile banner'));
    await tester.pumpAndSettle();

    expect(calls, contains('DELETE /me/banner'));
    expect(find.text('Profile colour'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove profile banner'), findsNothing);
  });
}
