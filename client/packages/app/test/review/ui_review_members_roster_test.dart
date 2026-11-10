// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The docked member roster, its bulk-moderation bar and sheet on a phone, and the moderation error band.
///
/// The pane has no search box, so there is no search-no-match state to capture.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_moderation_error.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/member_selection.dart';

import '../ui_snapshot_support.dart';
import 'members_review_data.dart';
import 'members_review_support.dart';

const _refused = 'Could not time Ada Lovelace out. Try again in a moment.';

Future<void> _pickTwo(ReviewRig rig) async {
  rig.container.read(memberSelectionProvider.notifier)
    ..enter()
    ..toggle('user-ada')
    ..toggle('user-grace');
  await rig.settle();
}

Future<void> _openDrawerSelecting(ReviewRig rig) async {
  await rig.tapTooltip('Members');
  await _pickTwo(rig);
}

void main() {
  setUpAll(loadRealFonts);

  const docked = [ReviewViewport.desktop];
  const drawer = [ReviewViewport.phone];

  reviewCase(
    'members-roster-docked',
    state: 'loading',
    viewports: docked,
    overrides: () => [
      channelMembersProvider.overrideWith(
        (ref, _) => Completer<List<api.UserProfile>>().future,
      ),
    ],
  );

  reviewCase(
    'members-roster-docked',
    state: 'error',
    viewports: docked,
    overrides: () => [
      channelMembersProvider.overrideWith(
        (ref, _) => throw const api.ServerException('boom', 500),
      ),
    ],
  );

  reviewCase(
    'members-roster-docked',
    state: 'selection',
    viewports: docked,
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: _pickTwo,
  );

  reviewCase(
    'sheet-member-moderation-bulk',
    state: 'bar',
    viewports: drawer,
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: _openDrawerSelecting,
  );

  reviewCase(
    'sheet-member-moderation-bulk',
    state: 'sheet',
    viewports: drawer,
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: (rig) async {
      await _openDrawerSelecting(rig);
      await rig.tapText('Moderate');
    },
  );

  reviewCase(
    'sheet-member-moderation-bulk',
    state: 'error',
    viewports: drawer,
    overrides: () => [reviewApi(reviewRosterReply)],
    drive: (rig) async {
      await _openDrawerSelecting(rig);
      rig.container.read(memberModerationErrorProvider.notifier).state =
          _refused;
      await rig.settle();
    },
  );

  reviewCase(
    'overlay-moderation-error',
    overrides: () => [
      reviewApi(reviewRosterReply),
      memberModerationErrorProvider.overrideWith((ref) => _refused),
    ],
  );
}
