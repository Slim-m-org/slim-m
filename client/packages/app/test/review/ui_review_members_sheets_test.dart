// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member-admin sheets: rename, password reset code, clear two-factor, and the password proof they share.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/widgets/reauth_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/clear_totp_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/member_rename_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/reset_code_sheet.dart';

import '../ui_snapshot_support.dart';
import 'members_review_data.dart';
import 'members_review_support.dart';

const _wrongPassword = {'error': 'that password is not correct'};
const _password = 'correct horse battery';

final _issued = {
  'code': 'RESET-7QK2-M9XD-4WLP-C8TN',
  'expires_at': DateTime.utc(2031, 5, 4, 12).millisecondsSinceEpoch,
};

Override _admin({required bool accepts}) => reviewApi((request) {
  final path = request.url.path;
  if (path.endsWith('/reset-code')) {
    return accepts ? reviewJson(_issued) : reviewJson(_wrongPassword, 403);
  }
  if (path.endsWith('/totp')) {
    return accepts ? reviewNoContent() : reviewJson(_wrongPassword, 403);
  }
  return null;
});

Override _renameRefused() => reviewApi(
  (request) => request.url.path.endsWith('/nickname')
      ? reviewJson({
          'error': 'you cannot rename somebody of your own rank',
        }, 403)
      : null,
);

Future<void> _openRename(ReviewRig rig, {String? nickname}) => rig.open(
  (context) => showRenameMemberSheet(
    context,
    profile: reviewSubject(nickname: nickname),
  ),
);

Future<void> _openResetCode(ReviewRig rig) => rig.open(
  (context) => showResetCodeSheet(
    context,
    subjectId: 'user-ada',
    subjectName: 'Ada Lovelace',
  ),
);

Future<void> _openClearTotp(ReviewRig rig) => rig.open(
  (context) => showClearTotpSheet(
    context,
    subjectId: 'user-ada',
    subjectName: 'Ada Lovelace',
  ),
);

Future<void> _proveAndSubmit(ReviewRig rig, String button) async {
  await rig.type(_password);
  await rig.tapText(button);
  await rig.settle();
}

Future<void> _openReauth(
  ReviewRig rig, {
  required ReauthSubmit onSubmit,
  bool askForCode = false,
}) => rig.open(
  (context) => showReauthSheet(
    context,
    title: 'Confirm it is you',
    description: askForCode
        ? 'Enter your password and a current code to delete this account.'
        : 'Enter your password to start setting up two-factor authentication.',
    submitLabel: askForCode ? 'Delete permanently' : 'Continue',
    askForCode: askForCode,
    dangerous: askForCode,
    onSubmit: onSubmit,
  ),
);

Future<String?> _refused(String password, String? code) async => reauthFailure(
  const api.ForbiddenException('that password is not correct'),
  'confirm the password',
);

void main() {
  setUpAll(loadRealFonts);

  reviewCase(
    'sheet-rename-member',
    state: 'prefilled',
    drive: (rig) => _openRename(rig, nickname: 'House DJ'),
  );

  reviewCase(
    'sheet-rename-member',
    state: 'error',
    overrides: () => [_renameRefused()],
    drive: (rig) async {
      await _openRename(rig);
      await rig.type('House DJ');
      await rig.tapText('Save name');
    },
  );

  reviewCase('sheet-reset-code', state: 'reauth', drive: _openResetCode);

  reviewCase(
    'sheet-reset-code',
    state: 'code',
    overrides: () => [_admin(accepts: true)],
    drive: (rig) async {
      await _openResetCode(rig);
      await _proveAndSubmit(rig, 'Generate code');
    },
  );

  reviewCase(
    'sheet-reset-code',
    state: 'error',
    overrides: () => [_admin(accepts: false)],
    drive: (rig) async {
      await _openResetCode(rig);
      await _proveAndSubmit(rig, 'Generate code');
    },
  );

  reviewCase('sheet-clear-totp', state: 'confirm', drive: _openClearTotp);

  reviewCase(
    'sheet-clear-totp',
    state: 'done',
    overrides: () => [_admin(accepts: true)],
    drive: (rig) async {
      await _openClearTotp(rig);
      await _proveAndSubmit(rig, 'Clear two-factor');
    },
  );

  reviewCase(
    'sheet-clear-totp',
    state: 'error',
    overrides: () => [_admin(accepts: false)],
    drive: (rig) async {
      await _openClearTotp(rig);
      await _proveAndSubmit(rig, 'Clear two-factor');
    },
  );

  reviewCase(
    'sheet-reauth',
    state: 'password',
    drive: (rig) => _openReauth(rig, onSubmit: _refused),
  );

  reviewCase(
    'sheet-reauth',
    state: 'password-and-code',
    drive: (rig) => _openReauth(rig, onSubmit: _refused, askForCode: true),
  );

  reviewCase(
    'sheet-reauth',
    state: 'wrong-password',
    drive: (rig) async {
      await _openReauth(rig, onSubmit: _refused);
      await _proveAndSubmit(rig, 'Continue');
    },
  );

  reviewCase(
    'sheet-reauth',
    state: 'busy',
    drive: (rig) async {
      await _openReauth(rig, onSubmit: (_, _) => Completer<String?>().future);
      await rig.type(_password);
      await rig.tapText('Continue');
    },
  );
}
