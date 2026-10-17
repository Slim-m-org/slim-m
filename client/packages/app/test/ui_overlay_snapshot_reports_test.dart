// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ReportCard`'s own combination states: which quick actions a moderator's
/// bits offer, the disabled-not-absent Jump exception, and the reporter and
/// subject lines' three-ways-of-reading-null shapes.
///
/// Pumped directly rather than through the reports screen's own list, the
/// same reduction `member_profile_test.dart` makes for the popover: the
/// composition rule under test lives in the card, and the queue chrome
/// around it needs a real fixture with report data the shared UI snapshot
/// fixture does not carry.
///
/// See screen-inventory-moderation.md's "Report flow" section. One
/// viewport (desktop).
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/settings/screens/admin/report_card.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _viewport = Size(1400, 880);

const _self = api.Me(
  id: 'user-nick',
  username: 'nick',
  displayName: 'Nick',
  createdAt: 0,
  permissions: 0,
);

api.Report _messageReport({
  String? subjectAuthorId = 'user-ada',
  String? snapshot =
      'Ok so hear me out, everyone should just go knock on their door.',
  int? channelPermissions,
}) => api.Report(
  id: 'report-1',
  reporterId: 'user-maya',
  subjectKind: api.ReportSubject.message,
  subjectId: 'm-report-1',
  channelId: 'c-general',
  reason: 'Names a real address and asks people to show up uninvited.',
  snapshot: snapshot,
  subjectAuthorId: subjectAuthorId,
  createdAt: 1753600400000,
  channelPermissions: channelPermissions,
);

/// A fixed answer, the shape `member_profile_block_test.dart`'s
/// `_FixedBlocks` already uses for a `StateNotifier`.
class _FixedProfiles extends BatchProfilesController {
  _FixedProfiles(super.ref, Map<String, api.UserProfile?> fixed) {
    state = fixed;
  }

  @override
  Future<void> resolve(Iterable<String> ids) async {}
}

/// [channelKnown] seeds the local store with `c-general` so `reportedChannelReachable`
/// answers true; omitted, the store stays empty and Jump renders disabled.
Future<void> _pumpReportCard(
  WidgetTester tester,
  api.Report report, {
  int permissions = 0,
  Map<String, api.UserProfile?> profiles = const {},
  bool channelKnown = true,
}) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  if (channelKnown) {
    await store.upsertChannels(const [
      api.Channel(id: 'c-general', name: 'general', kind: 'text', createdAt: 0),
    ]);
  }

  final container = ProviderContainer(
    overrides: [
      myPermissionsProvider.overrideWithValue(permissions),
      meProvider.overrideWith((ref) async => _self),
      membersProvider.overrideWith((ref) async => const []),
      databaseProvider.overrideWith((ref) async => db),
      storeProvider.overrideWith((ref) async => store),
      batchProfilesControllerProvider.overrideWith(
        (ref) => _FixedProfiles(ref, profiles),
      ),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500,
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: ReportCard(report: report),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('every quick action present, full moderation rights', (
    tester,
  ) async {
    await _pumpReportCard(
      tester,
      _messageReport(channelPermissions: Perm.manageMessages),
      permissions: Perm.manageMessages | Perm.kickMembers | Perm.banMembers,
      profiles: const {
        'user-maya': api.UserProfile(
          id: 'user-maya',
          username: 'maya',
          displayName: 'Maya',
          createdAt: 0,
        ),
        'user-ada': api.UserProfile(
          id: 'user-ada',
          username: 'ada',
          displayName: 'Ada Lovelace',
          createdAt: 0,
        ),
      },
    );
    await _finish(tester, 'report-card-message-full-actions-desktop');
  });

  testWidgets('no permission bits: the whole quick-actions block is absent', (
    tester,
  ) async {
    await _pumpReportCard(tester, _messageReport());
    await _finish(tester, 'report-card-no-quick-actions-desktop');
  });

  testWidgets(
    "a DM's own channel_permissions never carries MANAGE_MESSAGES, so Delete "
    'is absent for an administrator too',
    (tester) async {
      await _pumpReportCard(
        tester,
        _messageReport(
          // DM_BASE minus manageMessages - no one is ever granted it in a DM.
          channelPermissions: Perm.viewChannel | Perm.sendMessages,
        ),
        // Every base bit, the real shape an administrator's base set holds.
        permissions: -1,
        profiles: const {
          'user-maya': api.UserProfile(
            id: 'user-maya',
            username: 'maya',
            displayName: 'Maya',
            createdAt: 0,
          ),
          'user-ada': api.UserProfile(
            id: 'user-ada',
            username: 'ada',
            displayName: 'Ada Lovelace',
            createdAt: 0,
          ),
        },
      );
      await _finish(tester, 'report-card-dm-administrator-desktop');
    },
  );

  testWidgets('Jump renders disabled, not absent, for an unreached channel', (
    tester,
  ) async {
    await _pumpReportCard(
      tester,
      _messageReport(channelPermissions: Perm.manageMessages),
      permissions: Perm.manageMessages,
      channelKnown: false,
    );
    await _finish(tester, 'report-card-jump-unreachable-desktop');
  });

  testWidgets('the reported subject is the viewing moderator: no self-'
      'moderation offered regardless of bits', (tester) async {
    await _pumpReportCard(
      tester,
      _messageReport(subjectAuthorId: 'user-nick'),
      permissions: Perm.kickMembers | Perm.banMembers,
      profiles: {'user-nick': _profileFromMe(_self)},
    );
    await _finish(tester, 'report-card-self-target-desktop');
  });

  testWidgets('the reported message\'s author has since left the Space', (
    tester,
  ) async {
    await _pumpReportCard(
      tester,
      _messageReport(subjectAuthorId: null),
      permissions: Perm.kickMembers | Perm.banMembers,
    );
    await _finish(tester, 'report-card-author-gone-desktop');
  });

  testWidgets('the reporter account has since been deleted', (tester) async {
    await _pumpReportCard(
      tester,
      _messageReport(),
      profiles: const {'user-maya': null, 'user-ada': null},
    );
    await _finish(tester, 'report-card-reporter-gone-desktop');
  });

  testWidgets('the reporter has not been resolved yet', (tester) async {
    // Distinct from report-card-no-quick-actions-desktop: this carries live actions.
    await _pumpReportCard(
      tester,
      _messageReport(channelPermissions: Perm.manageMessages),
      permissions: Perm.manageMessages,
      profiles: const {},
    );
    await _finish(tester, 'report-card-reporter-resolving-desktop');
  });

  testWidgets('the server already withheld the reporter (anonymous)', (
    tester,
  ) async {
    await _pumpReportCard(
      tester,
      const api.Report(
        id: 'report-2',
        reporterId: null,
        subjectKind: api.ReportSubject.user,
        subjectId: 'user-maya',
        channelId: null,
        reason: 'Keeps derailing off topic.',
        snapshot: null,
        subjectAuthorId: null,
        createdAt: 1753600300000,
      ),
      profiles: const {
        'user-maya': api.UserProfile(
          id: 'user-maya',
          username: 'maya',
          displayName: 'Maya',
          createdAt: 0,
        ),
      },
    );
    await _finish(tester, 'report-card-reporter-anonymous-desktop');
  });

  testWidgets('no snapshot: deleted before capture, or a user-kind report', (
    tester,
  ) async {
    await _pumpReportCard(
      tester,
      const api.Report(
        id: 'report-3',
        reporterId: 'user-maya',
        subjectKind: api.ReportSubject.user,
        subjectId: 'user-ada',
        channelId: null,
        reason: 'Repeated harassment in DMs.',
        snapshot: null,
        subjectAuthorId: null,
        createdAt: 1753600300000,
      ),
      permissions: Perm.kickMembers,
      profiles: const {
        'user-maya': api.UserProfile(
          id: 'user-maya',
          username: 'maya',
          displayName: 'Maya',
          createdAt: 0,
        ),
        'user-ada': api.UserProfile(
          id: 'user-ada',
          username: 'ada',
          displayName: 'Ada Lovelace',
          createdAt: 0,
        ),
      },
    );
    await _finish(tester, 'report-card-no-snapshot-desktop');
  });
}

/// [api.Report.subjectAuthorId]/[reporterId] resolve through the same
/// `UserProfile` map a message author would, so the caller's own [api.Me]
/// needs a profile-shaped entry too when it is the one named.
api.UserProfile _profileFromMe(api.Me me) => api.UserProfile(
  id: me.id,
  username: me.username,
  displayName: me.displayName,
  createdAt: me.createdAt,
);
