// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders one settings pane in a window tall enough that every lazily built
/// row exists, and reads back the label of each settings row on it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/settings/widgets/settings_detail_row.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_segmented_row.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_slider_row.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import 'features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import 'ui_snapshot_support.dart';

/// One settings row as rendered: its label and whatever describes it.
typedef RenderedRow = ({String label, String? description});

/// The real app at [route] in a [size] window; tear down with [teardownFixture].
Future<({ProviderContainer container, SlimmDatabase db})> pumpSettingsAt(
  WidgetTester tester,
  String route, {
  Size size = const Size(1400, 9000),
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => SnapshotVoiceController(ref, const VoiceState()),
      ),
    ],
  );
  final router = fixtureRouter(route);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          theme: brightness == Brightness.dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
          builder: appChromeBuilder,
        ),
      ),
    ),
  );
  if (isModalFixtureRoute(route)) {
    await tester.pump();
    unawaited(router.push(route));
  }
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  return fixture;
}

/// Every settings row on [route] (a settings URL with `?pane=`).
Future<List<RenderedRow>> renderedSettingsRows(
  WidgetTester tester,
  String route,
) async {
  final fixture = await pumpSettingsAt(tester, route);
  final rows = <RenderedRow>[];
  void add(String? label, String? description) {
    if (label != null && label.isNotEmpty) {
      rows.add((label: label, description: description));
    }
  }

  for (final e in find.byType(SettingsToggleRow).evaluate()) {
    final w = e.widget as SettingsToggleRow;
    add(w.label, w.description);
  }
  for (final e
      in find.byWidgetPredicate((w) => w is SettingsSelectRow).evaluate()) {
    final w = e.widget as SettingsSelectRow;
    add(w.label, w.description ?? w.sheetFootnote);
  }
  for (final e
      in find.byWidgetPredicate((w) => w is SettingsSegmentedRow).evaluate()) {
    final w = e.widget as SettingsSegmentedRow;
    add(w.label, w.description ?? w.footnote);
  }
  for (final e in find.byType(SettingsSliderRow).evaluate()) {
    add((e.widget as SettingsSliderRow).label, null);
  }
  for (final e in find.byType(SettingsSectionCard).evaluate()) {
    final w = e.widget as SettingsSectionCard;
    add(w.title, w.description);
  }
  for (final e in find.byType(SettingsDetailRow).evaluate()) {
    final w = e.widget as SettingsDetailRow;
    add(w.title, w.detail);
  }
  await teardownFixture(tester, fixture.container, fixture.db);
  return rows;
}
