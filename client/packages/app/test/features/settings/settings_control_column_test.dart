// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Appearance's control column, read from the real pane: on a laptop every
/// segmented control and slider track starts on one edge and ends at the
/// card's inset, and on a phone each spans the card; a doubled text size on a
/// phone overflows nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_control_column.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_slider_row.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../snapshots/ui_snapshot_appearance_fixture.dart';
import '../../ui_snapshot_support.dart';

const _route = '/settings?pane=appearance';
const _inset = AppSpacing.s16;

final _segments = find.byWidgetPredicate((w) => w is AppSegmentedControl);
final _sliders = find.byWidgetPredicate((w) => w is AppSlider);

/// The card [control] sits in, without its insets.
Rect _cardInner(WidgetTester tester, Finder control) {
  final card = tester.getRect(
    find
        .ancestor(
          of: control,
          matching: find.byWidgetPredicate((w) => w is SettingsSectionCard),
        )
        .first,
  );
  return Rect.fromLTRB(
    card.left + _inset,
    card.top,
    card.right - _inset,
    card.bottom,
  );
}

/// Where the slider's track runs: its box less the inset on each side.
Rect _track(WidgetTester tester, Finder slider) {
  final box = tester.getRect(slider);
  return Rect.fromLTRB(
    box.left + AppSlider.trackInset,
    box.top,
    box.right - AppSlider.trackInset,
    box.bottom,
  );
}

List<Finder> _each(Finder finder) => [
  for (var i = 0; i < finder.evaluate().length; i++) finder.at(i),
];

Future<void> _render(
  WidgetTester tester,
  String viewport,
  Future<void> Function(WidgetTester tester) check, {
  TextScaler? textScaler,
}) async => renderSurface(
  tester,
  _route,
  viewport,
  'dark',
  'settings-control-column-$viewport',
  overrides: await backgroundPictureOverrides(tester),
  textScaler: textScaler,
  afterSettle: check,
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('on a laptop every control shares the column', (tester) async {
    await _render(tester, 'laptop-1280', (tester) async {
      final segments = _each(_segments);
      final sliders = _each(_sliders);
      expect(
        segments,
        hasLength(4),
        reason: 'Clock, Motion, Density, Thread lines',
      );
      expect(sliders, hasLength(4), reason: 'Dim, Blur, scale and spacing');

      final inner = _cardInner(tester, segments.first);
      final left = inner.right - kSettingsControlColumnWidth;
      for (final s in segments) {
        final rect = tester.getRect(s);
        expect(rect.left, moreOrLessEquals(left), reason: '$s left');
        expect(rect.right, moreOrLessEquals(inner.right), reason: '$s right');
      }
      for (final s in sliders) {
        final track = _track(tester, s);
        expect(track.left, moreOrLessEquals(left), reason: '$s left');
        expect(track.right, lessThanOrEqualTo(inner.right + 0.01));
      }
    });
  });

  testWidgets('on a laptop a slider value ends at the inset with its unit', (
    tester,
  ) async {
    await _render(tester, 'laptop-1280', (tester) async {
      for (final label in ['Interface scale', 'Space between groups']) {
        final row = find.byWidgetPredicate(
          (w) => w is SettingsSliderRow && w.label == label,
        );
        final widget = tester.widget<SettingsSliderRow>(row);
        expect(widget.valueLabel, matches(RegExp(r'^\d+( px|%)$')));
        expect(widget.minLabel, matches(RegExp(r'^\d+( px|%)$')));
        expect(widget.maxLabel, matches(RegExp(r'^\d+( px|%)$')));
        final value = find
            .descendant(of: row, matching: find.text(widget.valueLabel))
            .first;
        final inner = _cardInner(tester, row);
        expect(
          tester.getRect(value).right,
          moreOrLessEquals(inner.right),
          reason: label,
        );
        final track = _track(
          tester,
          find.descendant(of: row, matching: _sliders),
        );
        final ends = find
            .descendant(of: row, matching: find.text(widget.minLabel))
            .last;
        expect(tester.getRect(ends).left, moreOrLessEquals(track.left));
        final max = find
            .descendant(of: row, matching: find.text(widget.maxLabel))
            .last;
        expect(tester.getRect(max).right, moreOrLessEquals(track.right));
      }
    });
  });

  testWidgets('on a phone every control spans its card', (tester) async {
    await _render(tester, 'phone-portrait', (tester) async {
      final controls = [..._each(_segments), ..._each(_sliders)];
      expect(controls, hasLength(8));
      for (final c in _each(_segments)) {
        final inner = _cardInner(tester, c);
        final rect = tester.getRect(c);
        expect(rect.left, moreOrLessEquals(inner.left), reason: '$c');
        expect(rect.width, moreOrLessEquals(inner.width), reason: '$c');
        expect(rect.height, greaterThanOrEqualTo(AppSizes.rowTouch));
      }
      for (final s in _each(_sliders)) {
        final inner = _cardInner(tester, s);
        final track = _track(tester, s);
        expect(track.left, moreOrLessEquals(inner.left), reason: '$s');
        expect(track.width, moreOrLessEquals(inner.width), reason: '$s');
      }
    });
  });

  testWidgets('a doubled text size on a phone overflows nothing', (
    tester,
  ) async {
    await _render(
      tester,
      'phone-portrait',
      (tester) async => expect(tester.takeException(), isNull),
      textScaler: const TextScaler.linear(2),
    );
  });
}
