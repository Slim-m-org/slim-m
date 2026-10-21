// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member card draws the banner image once a live profile edit lands,
/// even while the roster snapshot behind it still has no banner.
library;

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/banner_bytes.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/features/members/widgets/profile_banner.dart';
import 'package:slimm_app/src/features/voice/providers/member_voice_channel.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _stale = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

const _fresh = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  bannerUpdatedAt: 7,
);

void main() {
  testWidgets('a banner set after the roster loaded shows on the card', (
    tester,
  ) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        myPermissionsProvider.overrideWithValue(0),
        membersProvider.overrideWith((ref) async => const [_stale]),
        rolesProvider.overrideWith((ref) async => const <api.Role>[]),
        storeProvider.overrideWith((ref) async => store),
        visibleVoiceChannelsProvider.overrideWith(
          (ref) => const Stream.empty(),
        ),
        bannerBytesProvider.overrideWith((ref, key) async => Uint8List(0)),
        mockApiOverride((request) async => throw StateError('no network')),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MemberProfileBody(
                profile: _stale,
                compact: false,
                onDone: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    ProfileBanner banner() => tester.widget(find.byType(ProfileBanner));
    expect(banner().bannerUpdatedAt, isNull);

    container.read(memberProfileOverridesProvider.notifier).applyKnown(_fresh);
    await tester.pump();

    expect(banner().bannerUpdatedAt, 7);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(minutes: 5));
  });
}
