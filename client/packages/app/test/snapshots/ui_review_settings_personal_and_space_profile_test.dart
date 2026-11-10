// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures for the personal settings nav search and the profile
/// sheets: photo menu, crop, display name and password.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/widgets/change_password_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_crop_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_photo_menu.dart';
import 'package:slimm_app/src/features/members/widgets/edit_display_name_sheet.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import '../ui_snapshot_support.dart';
import 'ui_review_settings_personal_and_space_support.dart';
import 'ui_review_settings_personal_and_space_photo.dart';

final _idleVoice = voiceControllerProvider.overrideWith(
  (ref) => SnapshotVoiceController(ref, const VoiceState()),
);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const Key('settings-search')), query);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _type(WidgetTester tester, String label, String text) =>
    tester.enterText(find.bySemanticsLabel(RegExp(label)), text);

/// Past the server's 64 character limit, so the counter and Save both react.
const _longName =
    'Alexandra Montgomery-Featherstonehaugh the Third of Westmorland and Kent';

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    final phone = viewport == 'phone';

    for (final (state, query) in const [
      ('search-results', 'notif'),
      ('search-empty', 'qqzx'),
    ]) {
      testWidgets('settings-personal-nav $state at $viewport', (tester) async {
        await reviewRoute(
          tester,
          surface: 'settings-personal-nav',
          state: state,
          viewport: viewport,
          route: '/settings',
          overrides: [_idleVoice],
          afterSettle: (t) => _search(t, query),
        );
      });
    }

    for (final hasPhoto in const [true, false]) {
      final state = hasPhoto ? 'with-picture' : 'no-picture';
      testWidgets('sheet-avatar-photo-menu $state at $viewport', (
        tester,
      ) async {
        await reviewOverlay(
          tester,
          surface: 'sheet-avatar-photo-menu',
          state: state,
          viewport: viewport,
          freshPerTheme: true,
          open: (context, ref) =>
              showAvatarPhotoMenu(context, canTake: phone, canRemove: hasPhoto),
        );
      });
    }

    for (final (state, aspect, circular, zoom) in const [
      ('circle', 1.0, true, false),
      ('banner', 3.0, false, false),
      ('zoomed', 1.0, true, true),
    ]) {
      testWidgets('sheet-avatar-crop $state at $viewport', (tester) async {
        final photo = await reviewPhotoPng(tester, 1600, 1200);
        await reviewOverlay(
          tester,
          surface: 'sheet-avatar-crop',
          state: state,
          viewport: viewport,
          open: (context, ref) => showAvatarCropSheet(
            context,
            photo,
            circular: circular,
            aspect: aspect,
          ),
          afterOpen: (t) async {
            await settleImages(t);
            if (zoom) await pinchOut(t);
          },
        );
      });
    }

    for (final (state, current, typed, failing) in const [
      ('prefilled', 'Nick', null, false),
      ('too-long', 'Nick', _longName, false),
      ('error', 'Nick', 'Nick Conn', true),
    ]) {
      testWidgets('sheet-edit-display-name $state at $viewport', (
        tester,
      ) async {
        await reviewOverlay(
          tester,
          surface: 'sheet-edit-display-name',
          state: state,
          viewport: viewport,
          overrides: [
            if (failing)
              reviewApi({
                'PATCH /me': jsonAnswer({
                  'error':
                      'display name contains a character that is not allowed',
                }, 422),
              }),
          ],
          open: (context, ref) => showEditDisplayNameSheet(context, current),
          afterOpen: (t) async {
            if (typed != null) {
              await _type(t, 'Display name', typed);
              await t.pump();
            }
            if (failing) {
              await t.tap(find.text('Save name'));
              await t.pump();
              await t.pump(const Duration(milliseconds: 100));
            }
          },
        );
      });
    }

    for (final (state, code, mismatch, error) in const [
      ('default', false, false, false),
      ('with-code', true, false, false),
      ('mismatch', false, true, false),
      ('error', false, false, true),
    ]) {
      testWidgets('sheet-change-password $state at $viewport', (tester) async {
        await reviewOverlay(
          tester,
          surface: 'sheet-change-password',
          state: state,
          viewport: viewport,
          open: (context, ref) => showChangePasswordSheet(
            context,
            askForCode: code,
            onSubmit: (current, next, code) async =>
                'That password is not correct.',
          ),
          afterOpen: (t) async {
            if (state == 'default') return;
            await _type(t, 'Current password', 'old-password');
            await _type(t, 'New password', 'long-enough-1');
            await _type(
              t,
              'Repeat new password',
              mismatch ? 'long-enough-2' : 'long-enough-1',
            );
            if (code) await _type(t, 'Authentication code', '123456');
            await t.pump();
            if (error) {
              await t.tap(find.text('Change password').last);
              await t.pump();
              await t.pump(const Duration(milliseconds: 100));
            }
          },
        );
      });
    }
  }
}
