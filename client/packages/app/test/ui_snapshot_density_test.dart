// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message list and the display settings at every density and interface
/// scale, at a phone and a desktop width, through the app's own chrome builder
/// so the scale is the one the app applies. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise each scene asserts it lays out cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/display_density.dart';
import 'package:slimm_app/src/widgets/appearance_settings_section.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'ui_snapshot_support.dart';

Widget _row(String id, String author, String content, {bool grouped = false}) =>
    MessageRow(
      key: ValueKey(id),
      message: message(
        id: id,
        authorId: author,
        authorDisplayName: author,
        content: content,
      ),
      grouped: grouped,
      showNewDivider: false,
      knownUsernames: const {},
      actions: noActions,
      editing: false,
      callbacks: MessageRowCallbacks(
        onRetry: noop,
        onDiscard: noop,
        onPickReaction: (_) {},
        onReactionTap: (_) {},
        onVote: (_) {},
        onSubmitEdit: (_) {},
        onCancelEdit: noop,
      ),
    );

final _messages = [
  _row('a', 'Priya', 'morning, did anyone look at the canvas bug'),
  _row('b', 'Priya', 'it looks like the seq ordering on resync', grouped: true),
  _row('c', 'Marco', 'yes, it was the seq ordering on resync'),
  _row('d', 'Priya', 'thanks, merging after ci'),
];

void main() {
  setUpAll(() async {
    await loadRealFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const widths = {'390': 390.0, '1280': 1280.0};
  const scenes = {'messages', 'settings'};
  for (final width in widths.entries) {
    for (final scene in scenes) {
      for (final density in AppDensity.values) {
        for (final scale in const [80, 100, 130]) {
          final spacing = density == AppDensity.compact ? 16 : 0;
          final name = '$scene-${width.key}-${density.name}-s$scale-g$spacing';
          testWidgets(name, (tester) async {
            tester.view.physicalSize = Size(width.value, 844);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);
            final container = ProviderContainer();
            addTearDown(container.dispose);
            await container
                .read(messageDensityControllerProvider.notifier)
                .select(density);
            await container
                .read(groupSpacingControllerProvider.notifier)
                .select(spacing);
            await container
                .read(uiScaleControllerProvider.notifier)
                .select(scale);
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: RepaintBoundary(
                  key: snapshotBoundary,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: buildTheme(Brightness.dark, AppTokens.dark),
                    builder: appChromeBuilder,
                    home: Scaffold(
                      body: ListView(
                        padding: scene == 'settings'
                            ? const EdgeInsets.all(AppSpacing.s16)
                            : EdgeInsets.zero,
                        children: scene == 'settings'
                            ? const [AppearanceSettingsSection()]
                            : _messages,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await writeSnapshot(tester, 'density-$name');
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
