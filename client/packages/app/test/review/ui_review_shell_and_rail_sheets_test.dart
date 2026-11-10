// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of the rail's two naming sheets: creating a channel (text,
/// voice, private with an audience, nameless, refused) and creating or
/// renaming a category.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'package:flutter/widgets.dart' show BuildContext, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/create_category_sheet.dart';
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/features/channels/widgets/manage_category_sheet.dart';
import 'package:slimm_data/data.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_data.dart';
import 'ui_review_shell_and_rail_actions.dart';
import 'ui_review_shell_and_rail_support.dart';

const _text = 'text';
const _voice = 'voice';

ShellStep _createChannel(
  String kind, {
  String? name,
  bool private = false,
  bool submit = false,
}) => (tester, scene) async {
  await openSheet(
    tester,
    (context) => showCreateChannelSheet(
      context,
      initialKind: kind,
      categoryId: kind == _text ? 'cat-text' : 'cat-voice',
      categoryName: kind == _text ? 'Text' : 'Voice',
    ),
  );
  if (name != null) {
    await tester.enterText(inputLabelled('Channel name'), name);
    await tester.pump();
  }
  if (private) {
    await tester.tap(find.bySemanticsLabel('Make this channel private'));
    await letRequestsLand(tester);
    for (final key in const ['role:role-admin', 'member:user-ada']) {
      await tester.tap(find.byKey(ValueKey('audience:$key')));
      await tester.pump();
    }
  }
  if (submit) {
    await tester.tap(find.text('Create channel'));
    await letRequestsLand(tester);
  }
};

ShellStep _categorySheet(
  Future<void> Function(BuildContext context) show, {
  String? name,
}) => (tester, scene) async {
  await openSheet(tester, show);
  if (name != null) {
    await tester.enterText(inputLabelled('Category name'), name);
    await tester.pump();
  }
};

void main() {
  setUpAll(loadRealFonts);

  for (final window in ShellWindow.values) {
    group('sheet-create-channel, ${window.slug}', () {
      for (final (state, arrange) in <(String, ShellStep)>[
        ('text', _createChannel(_text, name: 'weekly-planning')),
        ('voice', _createChannel(_voice, name: 'Game night')),
        (
          'private-audience',
          _createChannel(_text, name: 'leads-only', private: true),
        ),
        ('name-missing', _createChannel(_text)),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'sheet-create-channel',
              state: state,
              seed: seedBusyRail,
              arrange: arrange,
            ),
          );
        });
      }

      testWidgets('error', (tester) async {
        await shootShell(
          tester,
          window,
          ShellCase(
            surface: 'sheet-create-channel',
            state: 'error',
            overrides: [
              apiHandler(
                (request) async =>
                    request.method == 'POST' && request.url.path == '/channels'
                    ? jsonAnswer({
                        'error': 'You cannot create channels here.',
                      }, 403)
                    : null,
              ),
            ],
            seed: seedBusyRail,
            arrange: _createChannel(
              _text,
              name: 'weekly-planning',
              submit: true,
            ),
          ),
        );
      });
    });

    group('sheet-category-name, ${window.slug}', () {
      const category = ChannelCategoryRow(
        id: 'cat-projects',
        name: 'Projects',
        position: 2,
      );
      for (final (state, arrange) in <(String, ShellStep)>[
        ('create-empty', _categorySheet(showCreateCategorySheet)),
        (
          'create-filled',
          _categorySheet(showCreateCategorySheet, name: 'Community events'),
        ),
        (
          'rename',
          _categorySheet(
            (context) => showRenameCategorySheet(context, category),
          ),
        ),
      ]) {
        testWidgets(state, (tester) async {
          await shootShell(
            tester,
            window,
            ShellCase(
              surface: 'sheet-category-name',
              state: state,
              seed: seedBusyRail,
              arrange: arrange,
            ),
          );
        });
      }
    });
  }
}
