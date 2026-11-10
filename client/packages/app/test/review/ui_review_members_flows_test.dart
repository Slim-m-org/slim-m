// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member flows that open over the shell: invite a friend, report, and the member picker.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/invite_friend.dart';
import 'package:slimm_app/src/features/members/widgets/member_picker.dart';
import 'package:slimm_app/src/features/members/widgets/report_dialog.dart';
import 'package:slimm_app/src/features/members/widgets/safety_actions.dart';
import 'package:slimm_app/src/features/messages/widgets/ephemeral_report.dart';
import 'package:slimm_app/src/providers/providers.dart' show serverUrlProvider;

import '../ui_snapshot_support.dart';
import 'members_review_data.dart';
import 'members_review_support.dart';

const _reason =
    'Posting the same invite link in every channel. It looks like spam from '
    'a throwaway account made today.';

class _ClipboardOnly implements InviteSharer {
  @override
  bool get canShare => false;

  @override
  Future<void> share(String link) async {}
}

List<Override> _inviting({required bool works}) => [
  serverUrlProvider.overrideWith(
    (ref) => Uri.parse('https://slim.example.com'),
  ),
  inviteSharerProvider.overrideWithValue(_ClipboardOnly()),
  reviewApi(
    (request) => request.url.path == '/invites' && request.method == 'POST'
        ? works
              ? reviewJson({
                  'code': 'K7F2M9QX',
                  'max_uses': 1,
                  'uses': 0,
                  'expires_at': DateTime.utc(
                    2031,
                    5,
                    5,
                    12,
                  ).millisecondsSinceEpoch,
                  'created_at': 0,
                  'revoked': false,
                  'usable': true,
                })
              : reviewJson({'error': 'the server could not make that'}, 500)
        : null,
  ),
];

Future<void> _openReport(ReviewRig rig) => rig.open(
  (context) => promptReportReason(context, subjectLabel: 'this message'),
);

const _privateReply = api.EphemeralMessage(
  id: 'eph-1',
  channelId: 'c-general',
  authorId: 'bot-jelly',
  authorDisplayName: 'jellyfin',
  content: 'Only you can see this: your watch history was cleared.',
  inReplyToId: 'm-1',
  createdAt: 1753600000000,
);

Future<void> _openPicker(ReviewRig rig) => rig.open(pickMember);

void main() {
  setUpAll(loadRealFonts);

  reviewCase(
    'sheet-invite-friend',
    state: 'link',
    overrides: () => _inviting(works: true),
    drive: (rig) async {
      unawaited(inviteAFriend(rig.context));
      await rig.settleReal();
    },
  );

  reviewCase(
    'sheet-invite-friend',
    state: 'error',
    overrides: () => _inviting(works: false),
    drive: (rig) async {
      unawaited(inviteAFriend(rig.context));
      await rig.settle();
    },
  );

  reviewCase('dialog-report', state: 'empty', drive: _openReport);

  reviewCase(
    'dialog-report',
    state: 'filled',
    drive: (rig) async {
      await _openReport(rig);
      await rig.type(_reason);
    },
  );

  reviewCase(
    'dialog-report',
    state: 'over-length',
    drive: (rig) async {
      await _openReport(rig);
      await rig.type('$_reason ' * 30);
    },
  );

  reviewCase(
    'dialog-report',
    state: 'filed',
    overrides: () => [
      reviewApi(
        (request) => request.url.path == '/reports'
            ? reviewJson({'id': 'report-1'}, 201)
            : null,
      ),
    ],
    drive: (rig) async {
      unawaited(
        fileReport(
          rig.context,
          rig.container,
          subject: api.ReportSubject.message,
          subjectId: 'm-1',
          subjectLabel: 'this message',
        ),
      );
      await rig.settle();
      await rig.type(_reason);
      await rig.tapText('Report');
      await rig.settle();
    },
  );

  reviewCase(
    'dialog-report',
    state: 'ephemeral',
    drive: (rig) =>
        rig.open((context) => reportEphemeralMessage(context, _privateReply)),
  );

  reviewCase(
    'sheet-member-picker',
    state: 'list',
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: _openPicker,
  );

  reviewCase(
    'sheet-member-picker',
    state: 'search',
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: (rig) async {
      await _openPicker(rig);
      await rig.type('gr');
      await rig.settle();
    },
  );

  reviewCase(
    'sheet-member-picker',
    state: 'no-match',
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: (rig) async {
      await _openPicker(rig);
      await rig.type('zzz');
      await rig.settle();
    },
  );

  reviewCase(
    'sheet-member-picker',
    state: 'empty',
    overrides: () => [
      reviewApi(
        (request) =>
            request.url.path.endsWith('/members') ? reviewJson([]) : null,
      ),
    ],
    drive: _openPicker,
  );
}
