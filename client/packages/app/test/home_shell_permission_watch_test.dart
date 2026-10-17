// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permission watcher must be alive from [HomeShell]'s own tree.
///
/// Its only watch site used to be [RolesScreen], a MANAGE_ROLES-gated modal
/// never co-mounted with any consumer of what the watcher invalidates, so
/// decision 0011's live invalidation never ran for an ordinary user. The
/// existing watcher tests all force-listen `roleChangeWatcherProvider`
/// directly, which is exactly why none of them could see that gap: this one
/// only pumps the shell, and the held [meProvider] listener is there so the
/// lazy invalidation has something to mark stale rather than an autoDispose
/// provider that would refetch on re-read regardless.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'features/settings/home_shell_harness.dart';

void main() {
  testWidgets('a RoleChanged refetches meProvider with only the shell '
      'mounted, no admin screen anywhere', (tester) async {
    var meFetches = 0;
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final s = setup(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/me') {
          meFetches++;
          return http.Response(
            jsonEncode({
              'id': 'bob',
              'username': 'bob',
              'display_name': 'Bob',
              'created_at': 0,
              'permissions': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final Object body = path.endsWith('/voice/roster')
            ? const {'participants': <Object>[]}
            : const <Object>[];
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      signedIn: true,
      extraOverrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    await pumpAtWidth(tester, s.container, 1200);

    final meSub = s.container.listen(meProvider, (_, __) {});
    await s.container.read(meProvider.future);
    final before = meFetches;

    events.add(const api.RoleChanged(roleId: 'r1'));
    await tester.pump();
    // Re-read, or a lazy invalidation is unobservable; see the library doc.
    await s.container.read(meProvider.future);
    expect(
      meFetches,
      before + 1,
      reason: 'the shell alone must keep roleChangeWatcherProvider alive',
    );

    meSub.close();
    await teardown(tester, s.container, s.db);
  });
}
