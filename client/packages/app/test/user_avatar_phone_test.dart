// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared person avatar - the one the member list, DM rows and profile
/// card all draw - shows a phone for a member online from a phone alone, and
/// the plain dot once a desktop joins them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

void main() {
  testWidgets(
    'a phone-only member shows the phone, a desktop restores the dot',
    (tester) async {
      final events = StreamController<ServerEvent>.broadcast(sync: true);
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(events.stream),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await events.close();
      });
      container.read(presenceControllerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(
              body: UserAvatar.known(
                name: 'Dana',
                userId: 'u2',
                avatarUpdatedAt: null,
                presence: true,
              ),
            ),
          ),
        ),
      );
      final phone = find.byIcon(AppIcons.presencePhone);

      void tell(Set<PresenceDevice> devices) => events.add(
        PresenceChanged(
          userId: 'u2',
          status: PresenceState.online,
          devices: devices,
        ),
      );

      tell({PresenceDevice.mobile});
      await tester.pump();
      expect(phone, findsOneWidget);
      expect(find.byType(AppStatusDot), findsNothing);

      tell({PresenceDevice.mobile, PresenceDevice.desktop});
      await tester.pumpAndSettle();
      expect(phone, findsNothing);
      expect(find.byType(AppStatusDot), findsOneWidget);
    },
  );
}
