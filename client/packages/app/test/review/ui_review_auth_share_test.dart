// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Share to", where the OS share sheet lands: the server step when several
/// are signed in, the destination list for text and for photos, and the
/// failure when nothing shared could be read. Phone and desktop, dark and
/// light.
///
/// Mounted in `modalPage` the way the real router does, so the desktop
/// presentation is the real floating panel.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/messages/providers/forward_targets.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/features/share/screens/share_to_screen.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';

import '../support/synthetic_png.dart';
import 'review_support.dart';

const _targets = [
  ForwardTarget(channelId: 'c-general', label: 'general', isDm: false),
  ForwardTarget(channelId: 'c-design', label: 'design', isDm: false),
  ForwardTarget(channelId: 'c-main', label: 'main', isDm: false, isVoice: true),
  ForwardTarget(
    channelId: 'c-staff',
    label: 'moderators-only-planning-and-escalations',
    isDm: false,
    restricted: true,
  ),
  ForwardTarget(
    channelId: 'c-dm-ada',
    label: 'Ada Lovelace',
    isDm: true,
    userId: 'user-ada',
    username: 'ada',
  ),
  ForwardTarget(
    channelId: 'c-dm-grace',
    label: 'Grace Hopper',
    isDm: true,
    userId: 'user-grace',
    username: 'grace',
  ),
];

const _link = IncomingShare(
  text: 'https://example.com/a-long-read-worth-saving',
);

const _report = SharedFile(
  path: '/cache/share/quarterly-report-final-v3.pdf',
  name: 'quarterly-report-final-v3.pdf',
  length: 2411724,
  mimeType: 'application/pdf',
);

GoRouter _shareRouter() => GoRouter(
  initialLocation: Routes.share,
  routes: [
    GoRoute(
      path: Routes.share,
      pageBuilder: (context, state) =>
          modalPage(context, const ShareToScreen()),
    ),
    GoRoute(path: Routes.channels, builder: (context, _) => const SizedBox()),
  ],
);

Future<void> _share(
  WidgetTester tester,
  String viewport,
  String state,
  IncomingShare share, {
  List<Override> extra = const [],
  ReviewAct? act,
}) => reviewRoute(
  tester,
  surface: 'route-share-to',
  state: state,
  viewport: viewport,
  route: Routes.share,
  router: _shareRouter(),
  overrides: [
    pendingShareProvider.overrideWith((ref) => PendingShare(share)),
    shareHandoffProvider.overrideWith((ref) => null),
    forwardTargetsProvider.overrideWith((ref, query) async => _targets),
    ...extra,
  ],
  act: act,
);

AccountEntry _signedInServer(
  WidgetTester tester,
  String host,
  String space, {
  required bool active,
}) {
  final container = ProviderContainer(
    overrides: [
      serverInfoProvider.overrideWith(
        (ref) async => api.Version(
          name: 'slim-m',
          version: '0.127.0',
          protocol: 1,
          spaceName: space,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return AccountEntry(
    account: Account.forServer(Uri.parse('https://$host')),
    container: container,
    active: active,
    signedIn: true,
    unread: AccountUnread.none,
    inCall: false,
  );
}

/// Three photos on disk, since the summary draws real thumbnails of them.
IncomingShare _photos(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('review-share');
  addTearDown(() => dir.deleteSync(recursive: true));
  return IncomingShare(
    files: [
      for (final (i, shade) in [60, 130, 200].indexed)
        () {
          final file = File('${dir.path}/IMG_000$i.png')
            ..writeAsBytesSync(solidPng(640, 480, shade: shade));
          return SharedFile(
            path: file.path,
            name: 'IMG_000$i.png',
            length: file.lengthSync(),
            mimeType: 'image/png',
          );
        }(),
    ],
  );
}

/// Reading a file and decoding it run outside the fake clock, one hop after another.
Future<void> _loadImages(WidgetTester tester, ReviewHandles handles) async {
  for (var hop = 0; hop < 6; hop++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadRealFonts);

  reviewCases(
    'route-share-to',
    state: 'server-step',
    body: (tester, viewport) => _share(
      tester,
      viewport,
      'server-step',
      const IncomingShare(files: [_report], text: 'Numbers for Thursday'),
      extra: [
        accountsSnapshotProvider.overrideWithValue(
          AccountsSnapshot(
            entries: [
              _signedInServer(
                tester,
                'chat.example',
                'Lamplight',
                active: true,
              ),
              _signedInServer(
                tester,
                'beta.example',
                'Beta Testers',
                active: false,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  reviewCases(
    'route-share-to',
    state: 'destinations',
    body: (tester, viewport) => _share(tester, viewport, 'destinations', _link),
  );

  reviewCases(
    'route-share-to',
    state: 'summary',
    body: (tester, viewport) =>
        _share(tester, viewport, 'summary', _photos(tester), act: _loadImages),
  );

  // Nothing the other app shared could be read, so there is no destination list at all.
  reviewCases(
    'route-share-to',
    state: 'unreadable',
    body: (tester, viewport) => _share(
      tester,
      viewport,
      'unreadable',
      const IncomingShare(unreadable: 2),
    ),
  );
}
