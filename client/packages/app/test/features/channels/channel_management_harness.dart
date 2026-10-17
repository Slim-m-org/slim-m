// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared fixture for the channel-management tests: a session, a caller
/// with chosen permissions, a mock-backed api, an in-memory local store and a
/// real GoRouter wired for the channel, channel-settings and list routes.
///
/// Split out when `channel_management_test.dart` crossed the file budget, so
/// its two halves (`channel_management_test.dart` and
/// `channel_settings_management_test.dart`) share one fixture rather than
/// each keeping a copy.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel channel(
  String id,
  String name, {
  String kind = 'text',
  String? topic,
  String? categoryId,
}) => Channel(
  id: id,
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  topic: topic,
  categoryId: categoryId,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

/// Wraps [child] with everything a sheet or the Channel settings screen's
/// provider reads need: a session, a caller with [permissions] (the settings
/// screen gates its own sections on `meProvider`, unlike the old sheet which
/// took `canManage` as a plain widget prop), an [apiProvider] backed by
/// [handler], an in-memory local store, and a real [GoRouter] (the create
/// sheet navigates to the new channel, and a deletion that closes the open
/// channel navigates back to the list, both through `GoRouter.of(context)`).
Widget harness(
  Widget child, {
  required http.Response Function(http.Request) handler,
  String initialLocation = '/',
  int permissions = Perm.manageChannels,
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(body: child),
      ),
      GoRoute(
        path: Routes.channels,
        builder: (context, state) => Scaffold(body: child),
      ),
      // The section stays mounted with a channel open, so a delete from Channel settings shows against the pane behind it.
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text('channel:${state.pathParameters['channelId']}'),
              Expanded(child: child),
            ],
          ),
        ),
      ),
      GoRoute(
        path: Routes.channelSettings,
        pageBuilder: (context, state) => modalPage(
          context,
          ChannelSettingsScreen(args: state.extra as ChannelSettingsRouteArgs?),
        ),
      ),
    ],
  );

  return UncontrolledProviderScope(
    container: ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
        meProvider.overrideWith(
          (ref) async => Me(
            id: 'user-1',
            username: 'user-1',
            displayName: 'User',
            createdAt: 0,
            permissions: permissions,
          ),
        ),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async => handler(request)),
          );
          ref.onDispose(api.close);
          return api;
        }),
        storeProvider.overrideWith((ref) async {
          final db = SlimmDatabase(NativeDatabase.memory());
          ref.onDispose(db.close);
          return MessageStore(db);
        }),
      ],
    ),
    child: MaterialApp.router(
      theme: buildTheme(Brightness.light, AppTokens.light),
      routerConfig: router,
    ),
  );
}
