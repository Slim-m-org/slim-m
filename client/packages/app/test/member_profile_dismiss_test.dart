// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bug this pins: `run` (and `_remove`) in `member_profile.dart` called
/// `widget.onDone()` - a real `Navigator.pop` - and only then awaited a
/// dialog before touching a provider. flutter_riverpod throws once the
/// popped element is disposed, so Remove and Report threw an unhandled async
/// error instead of acting.
///
/// Every mount in `member_profile_test.dart` passes `onDone: () {}`, which
/// never disposes anything and could not have caught this. These tests open
/// the popover through the real [showMemberProfile] instead, so `onDone`
/// really does pop the route and really does dispose `MemberProfileBody`
/// while the action is still in flight - the one thing that makes this a
/// real regression test rather than a restatement of the fix.
///
/// Message, Block and Unblock are asserted too, on the same container-based
/// path, but mutation testing (reverting to the pre-fix `ref`-based code)
/// found only Remove and Report actually crash here. Message's `ref` touch
/// comes after a real network await, which is exactly the race the finding
/// describes, but `tester.pump` resolves a mocked response's `Future` before
/// it finalizes the pop's disposal within the same call, so the race cannot
/// be forced deterministically from this harness - not evidence the bug is
/// imaginary, since a real server has no such ordering guarantee. Block and
/// Unblock's only touch of the disposable handle is a single synchronous read
/// before their first `await`, which can never observe a disposal that always
/// needs at least one more frame to land, so their crash is not reproducible
/// at all, contrary to what this finding says. All three are still worth
/// having on the container-based path, since the property should not depend
/// on which of these five happens to read synchronously, or fast enough,
/// today.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

import 'support/reduced_motion_harness.dart';

/// Keeps the real controller's websocket and its retry timer out of a test
/// that only needs presence providers to resolve.
class _NoSocketSync extends SyncController {
  _NoSocketSync(super.ref) {
    state = SyncStatus.live;
  }

  @override
  Future<void> start() async {}
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A container whose fake server records every request it answers, so a test
/// can assert the write actually happened rather than merely that nothing
/// threw.
({ProviderContainer container, List<String> requests}) _wire({
  int permissions = 0,
  List<String> blocked = const [],
}) {
  final requests = <String>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(_NoSocketSync.new),
      databaseProvider.overrideWith((ref) async => db),
      myPermissionsProvider.overrideWithValue(permissions),
      membersProvider.overrideWith((ref) async => [_other]),
      rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add('${request.method} ${request.url.path}');
            if (request.url.path == '/blocks') return _json(blocked);
            if (request.url.path == '/reports') {
              return _json({'id': 'report-1'});
            }
            if (request.url.path == '/dms/${_other.id}') {
              return _json({
                'channel_id': 'dm-1',
                'user': {
                  'id': _other.id,
                  'username': _other.username,
                  'display_name': _other.displayName,
                  'created_at': 0,
                },
                'unread': 0,
                'created_at': 500,
              });
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, requests: requests);
}

/// The "open" button lives on this route's own page, inside the GoRouter's
/// Navigator: "Message" calls `host.go`, which needs a `GoRouter` ancestor,
/// the same as it would in the real shell.
Widget _openPage(BuildContext context, GoRouterState state) => Scaffold(
  body: Consumer(
    builder: (context, ref, _) => TextButton(
      onPressed: () => showMemberProfile(context, profile: _other),
      child: const Text('open'),
    ),
  ),
);

GoRouter _testRouter() => GoRouter(
  initialLocation: '/channels',
  routes: [
    GoRoute(path: '/channels', builder: _openPage),
    GoRoute(
      path: Routes.channelPattern,
      builder: (context, state) => const Scaffold(body: Text('conversation')),
    ),
  ],
);

/// Opens the profile through the real [showMemberProfile], never
/// `MemberProfileBody` directly: that is what wires `onDone` to a genuine
/// `Navigator.pop` rather than a no-op every earlier test passed instead.
///
/// Reduce-motion is forced on so the popover's transition duration is zero -
/// the finding's own words are "under reduce-motion is always", since a zero
/// duration lets the pop dispose the element on the spot rather than after an
/// animation, which is what makes the race deterministic instead of a timing
/// gamble a fast fake server could win by luck.
Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    reducedMotionRouterApp(container: container, router: _testRouter()),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Advances well past the popover's own reverse transition
/// (`AppMotion.base`, 180ms) - the disposal this bug depended on racing.
Future<void> _settleDismiss(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('Message reaches the API rather than throwing past the dismiss', (
    tester,
  ) async {
    final wired = _wire();
    await _open(tester, wired.container);

    await tester.tap(find.text('Message'));
    await _settleDismiss(tester);

    expect(tester.takeException(), isNull);
    expect(wired.requests, contains('POST /dms/user-maya'));
  });

  testWidgets('Remove reaches the API rather than throwing past the dismiss', (
    tester,
  ) async {
    final wired = _wire(permissions: Perm.banMembers);
    await _open(tester, wired.container);

    await tester.tap(find.text('Moderate...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from Space...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await _settleDismiss(tester);

    expect(tester.takeException(), isNull);
    expect(wired.requests, contains('PUT /members/user-maya/removal'));
  });

  testWidgets('Report reaches the API rather than throwing past the dismiss', (
    tester,
  ) async {
    final wired = _wire();
    await _open(tester, wired.container);

    await tester.tap(find.text('Report user'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'spam');
    await tester.pump();
    await tester.tap(find.text('Report'));
    await _settleDismiss(tester);

    expect(tester.takeException(), isNull);
    expect(wired.requests, contains('POST /reports'));
  });

  testWidgets('Block reaches the API rather than throwing past the dismiss', (
    tester,
  ) async {
    final wired = _wire();
    await _open(tester, wired.container);

    await tester.tap(find.text('Block'));
    await _settleDismiss(tester);

    expect(tester.takeException(), isNull);
    expect(wired.requests, contains('POST /blocks/user-maya'));
  });

  testWidgets('Unblock reaches the API rather than throwing past the dismiss', (
    tester,
  ) async {
    final wired = _wire(blocked: ['user-maya']);
    await _open(tester, wired.container);

    await tester.tap(find.text('Unblock'));
    await _settleDismiss(tester);

    expect(tester.takeException(), isNull);
    expect(wired.requests, contains('DELETE /blocks/user-maya'));
  });
}
