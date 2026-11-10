// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reaction picker: the panel anchored to a hovered message row on a
/// desktop window, and the bottom sheets a phone gets (the whole catalog, and
/// the Space's own emoji alone). Resting, searched, no match and with the
/// Space's emoji on top. Dark and light; the PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_design_system/design_system.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

const _surface = 'popover-emoji-reaction-picker';

Finder get _addReaction => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == ActionLabels.addReaction,
);

Finder get _search => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Search emoji',
);

TestGesture? _hovering;

Future<void> _dropMouse() async {
  final mouse = _hovering;
  _hovering = null;
  await mouse?.removePointer();
}

/// Hovers a message row so its toolbar shows, then opens the picker from it.
///
/// One mouse per mount: the capture mounts twice, and a second pointer
/// cannot be added while the first is still on screen.
Future<void> _openFromRow(WidgetTester tester) async {
  await _dropMouse();
  final mouse = _hovering = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  addTearDown(_dropMouse);
  await mouse.addPointer(location: const Offset(-50, -50));
  final row = tester.getCenter(find.byKey(const ValueKey('m-3')));
  // The first move only enters the row; the toolbar answers the second.
  await mouse.moveTo(row - const Offset(200, 0));
  await tester.pump(const Duration(milliseconds: 100));
  await mouse.moveTo(row);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(_addReaction);
  await settle(tester);
}

Future<void> _query(WidgetTester tester, String text) async {
  await tester.enterText(_search, text);
  await settle(tester);
}

void _desktop(
  String state, {
  bool spaceEmoji = false,
  Future<void> Function(WidgetTester tester)? then,
}) => reviewCases(
  _surface,
  state: state,
  viewports: const ['desktop'],
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewRoute(
      tester,
      surface: _surface,
      state: state,
      viewport: viewport,
      themes: themes,
      overrides: composerSeeds(spaceEmoji: spaceEmoji),
      act: (tester, _) async {
        await _openFromRow(tester);
        await then?.call(tester);
      },
    ),
  ),
);

void _phone(
  String state,
  Future<void> Function(BuildContext context) open, {
  bool spaceEmoji = false,
  Future<void> Function(WidgetTester tester)? then,
}) => reviewCases(
  _surface,
  state: state,
  viewports: const ['phone'],
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewOverlay(
      tester,
      surface: _surface,
      state: state,
      viewport: viewport,
      themes: themes,
      overrides: composerSeeds(spaceEmoji: spaceEmoji),
      open: (context, ref) => open(context),
      afterOpen: (tester, _) async {
        await settle(tester);
        await then?.call(tester);
      },
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  _desktop('picker');
  _desktop('search', then: (tester) => _query(tester, 'smile'));
  _desktop('no-match', then: (tester) => _query(tester, 'zzqx'));
  _desktop('space-emoji', spaceEmoji: true);

  Future<void> sheet(BuildContext context) =>
      showEmojiPickerSheet(context, onSelect: (_) {});
  _phone('picker', sheet);
  _phone('search', sheet, then: (tester) => _query(tester, 'smile'));
  _phone('no-match', sheet, then: (tester) => _query(tester, 'zzqx'));
  _phone(
    'space-emoji',
    (context) => showSpaceEmojiSheet(context, onSelect: (_) {}),
    spaceEmoji: true,
  );
}
