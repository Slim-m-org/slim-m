// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Audit log pane: rows, empty and error states, paging, and the
/// MANAGE_SERVER gate on the pane itself.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/settings/providers/admin_audit_names.dart';
import 'package:slimm_app/src/features/settings/providers/admin_audit_wording.dart';
import 'package:slimm_app/src/features/settings/screens/admin/audit_log_screen.dart';
import 'package:slimm_app/src/features/settings/screens/space_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'admin-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _entry(int id, {String action = 'channel.delete'}) => {
  'id': id,
  'actor_id': null,
  'action': action,
  'target_id': 'c$id',
  'detail': {'name': 'room-$id'},
  'created_at': DateTime.now().millisecondsSinceEpoch - id * 60000,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Future<List<Uri>> _pump(
  WidgetTester tester,
  http.Response Function(Uri url) answer,
) async {
  final seen = <Uri>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      adminAuditNamesProvider.overrideWith((ref) => const AuditNames()),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            seen.add(request.url);
            if (request.url.path == '/space/audit-log') {
              return answer(request.url);
            }
            return _json(<Object>[]);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AuditLogPane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return seen;
}

void main() {
  testWidgets('shows a sentence per row, with a deleted actor named', (
    tester,
  ) async {
    await _pump(tester, (_) => _json([_entry(2), _entry(1)]));
    expect(
      find.textContaining('deleted #room-2', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Deleted account', findRichText: true),
      findsNWidgets(2),
    );
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('an empty log says so', (tester) async {
    await _pump(tester, (_) => _json(<Object>[]));
    expect(find.text('No changes recorded yet'), findsOneWidget);
  });

  testWidgets('a failure shows the persistent error state, not a snackbar', (
    tester,
  ) async {
    await _pump(tester, (_) => _json({'error': 'nope'}, 500));
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a full page offers Load more, which pages with before', (
    tester,
  ) async {
    final seen = await _pump(tester, (url) {
      if (url.queryParameters['before'] == null) {
        return _json([for (var i = 100; i > 50; i--) _entry(i)]);
      }
      return _json([_entry(7)]);
    });
    await tester.scrollUntilVisible(find.text('Load more'), 200);
    expect(find.text('Load more'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    final second = seen.where((u) => u.queryParameters['before'] != null);
    expect(second.single.queryParameters['before'], '51');
    expect(find.text('Load more'), findsNothing);
  });

  group('pane gating', () {
    Future<List<String>> panes(WidgetTester tester, int mine) async {
      late List<SettingsPaneGroup> groups;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myPermissionsProvider.overrideWithValue(mine),
            myVisibleChannelsProvider.overrideWith((ref) async => <Channel>[]),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                groups = spaceSettingsPaneGroups(context, ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return [
        for (final g in groups)
          for (final p in g.panes) p.label,
      ];
    }

    testWidgets('MANAGE_SERVER sees Audit log', (tester) async {
      expect(await panes(tester, Perm.manageServer), contains('Audit log'));
    });

    testWidgets('without MANAGE_SERVER it is hidden', (tester) async {
      final labels = await panes(
        tester,
        Perm.manageRoles | Perm.createInvite | Perm.manageMessages,
      );
      expect(labels, isNot(contains('Audit log')));
    });
  });
}
