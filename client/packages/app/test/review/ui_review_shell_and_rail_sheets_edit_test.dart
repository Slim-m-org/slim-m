// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the sheets that edit something that already exists: the
/// status editor, a category's permissions grid and a voice room's options.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/category_permissions_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/status_editor_sheet.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_room_settings_sheet.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_data.dart';
import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_support.dart';

const _status = 'Heads down on the release until 3pm';

/// Longer than the 80 characters a status may hold.
const _tooLong =
    'Out of office until the first week of next month, '
    'back on the thirteenth and answering mail slowly';

ShellStep _statusEditor(String current, {String? typed, bool save = false}) =>
    (tester, scene) async {
      await openSheet(
        tester,
        (context) => showStatusEditorSheet(context, current),
      );
      if (typed != null) {
        await tester.enterText(inputLabelled('Status text'), typed);
        await tester.pump();
      }
      if (save) {
        await tester.tap(find.text('Save'));
        await letRequestsLand(tester);
      }
    };

Override _refuseStatus() => apiHandler(
  (request) async => request.method == 'PATCH' && request.url.path == '/me'
      ? jsonAnswer({'error': 'The server could not save that.'}, 500)
      : null,
);

final _overwrites = {
  'overwrites': [
    {
      'kind': 'role',
      'id': 'role-everyone',
      'allow': Perm.viewChannel | Perm.sendMessages,
      'deny': Perm.mentionEveryone,
    },
    {
      'kind': 'member',
      'id': 'user-ada',
      'allow': Perm.attachFiles | Perm.addReactions,
      'deny': 0,
    },
    {
      'kind': 'member',
      'id': 'user-long-name',
      'allow': 0,
      'deny': Perm.sendMessages | Perm.createInvite,
    },
  ],
};

Override _categoryGrid() => apiHandler(
  (request) async => request.url.path == '/categories/cat-text/overwrites'
      ? jsonAnswer(_overwrites)
      : null,
);

ShellStep _categoryPermissions({bool edit = false}) => (tester, scene) async {
  await openSheet(
    tester,
    (context) => showCategoryPermissionsSheet(
      context,
      categoryId: 'cat-text',
      categoryName: 'Text',
    ),
  );
  await letRequestsLand(tester);
  if (edit) {
    final cell = find.byKey(
      const ValueKey('cell:role:role-everyone:${Perm.manageMessages}'),
    );
    await tester.tap(cell);
    await tester.pump(const Duration(milliseconds: 350));
    // The save bar sits under the grid, so it scrolls into view for the capture.
    await tester.ensureVisible(find.text('Save changes'));
    await tester.pump(const Duration(milliseconds: 350));
  }
};

ShellStep _roomOptions(String roomId) => (tester, scene) async {
  final store = await scene.container.read(storeProvider.future);
  final room = (await store.allChannels()).firstWhere((c) => c.id == roomId);
  await openSheet(
    tester,
    (context) => showVoiceRoomSettingsSheet(context, room: room),
  );
};

void main() {
  setUpAll(loadRealFonts);

  group('sheet-status-editor, phone', () {
    for (final (state, arrange, overrides)
        in <(String, ShellStep, List<Override>)>[
          ('empty', _statusEditor(''), const []),
          ('existing', _statusEditor(_status), const []),
          ('over-length', _statusEditor(_status, typed: _tooLong), const []),
          (
            'save-error',
            _statusEditor('', typed: _status, save: true),
            [_refuseStatus()],
          ),
        ]) {
      testWidgets(state, (tester) async {
        await shootShell(
          tester,
          ShellWindow.phone,
          ShellCase(
            surface: 'sheet-status-editor',
            state: state,
            overrides: [meOverride(memberPermissions), ...overrides],
            seed: seedBusyRail,
            arrange: arrange,
          ),
        );
      });
    }
  });

  for (final window in ShellWindow.values) {
    group('sheet-category-permissions, ${window.slug}', () {
      for (final (state, edit) in [('default', false), ('dirty', true)]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'sheet-category-permissions',
              state: state,
              overrides: [_categoryGrid()],
              seed: seedBusyRail,
              arrange: _categoryPermissions(edit: edit),
            ),
          );
        });
      }
    });

    group('sheet-voice-room-settings, ${window.slug}', () {
      for (final (state, room, overrides) in <(String, String, List<Override>)>[
        ('owner', 'c-room-nick', [meOverride(memberPermissions)]),
        ('manager', 'c-room-ada', const []),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'sheet-voice-room-settings',
              state: state,
              overrides: overrides,
              seed: seedBusyRail,
              arrange: _roomOptions(room),
            ),
          );
        });
      }
    });
  }
}
