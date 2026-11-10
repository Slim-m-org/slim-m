// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The searchable choice picker a settings row opens once it has more than
/// eight choices (a dropdown from 600 wide, a sheet below it), and the colour
/// picker. Dark and light; the PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
///
/// The colour picker has no recent colours of its own: they live in the
/// canvas pen menu's swatch row, so no `recents` case stands here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

const _channels = [
  'general',
  'design',
  'engineering',
  'frontend',
  'backend',
  'infra',
  'announcements',
  'releases',
  'support',
  'off-topic',
  'music',
  'photos',
  'book-club',
  'game-night',
];

Widget _schedulePage(BuildContext context) => Scaffold(
  body: SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SettingsSectionCard(
          title: 'Schedule',
          children: [
            SettingsSelectRow<String>(
              label: 'Posts in',
              value: 'general',
              choices: [
                for (final name in _channels)
                  SettingsChoice(value: name, label: '#$name'),
              ],
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    ),
  ),
);

void _choice(String state, {String? query}) => reviewCases(
  'sheet-searchable-choice',
  state: state,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewWidget(
      tester,
      surface: 'sheet-searchable-choice',
      state: state,
      viewport: viewport,
      themes: themes,
      build: _schedulePage,
      act: (tester, _) async {
        await tester.tap(find.text('Posts in'));
        await settle(tester);
        if (query == null) return;
        await tester.enterText(
          find.byKey(const ValueKey('choice-search')),
          query,
        );
        await settle(tester);
      },
    ),
  ),
);

void _colour(String state, {String? hex}) => reviewCases(
  'dialog-colour-picker',
  state: state,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewOverlay(
      tester,
      surface: 'dialog-colour-picker',
      state: state,
      viewport: viewport,
      themes: themes,
      open: (context, ref) =>
          showAppColourPicker(context, initial: const Color(0xFF3A7BD5)),
      afterOpen: (tester, _) async {
        if (hex == null) return;
        await tester.enterText(find.byKey(AppColourPicker.hexFieldKey), hex);
        // Drops the cursor handle a tap leaves on a touch-platform field.
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
      },
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  _choice('long-list');
  _choice('filtered', query: 'en');
  _choice('no-match', query: 'zzzq');

  _colour('default');
  _colour('invalid-hex', hex: '#3A7BZZ');
}
