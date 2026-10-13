// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The assembled canvas pane - dock, face-pile, self bubble and surface,
/// together - rendered at real widths in all three themes, with realistic
/// content rather than a handful of test objects.
///
/// This exists because #460's redesign shipped through a rescued,
/// five-conflict landing with nobody having looked at the result on a
/// screen: see PR #460 and the commits around it for why. Every other
/// widget test in this package proves one behaviour in isolation; this one
/// proves the composition - whether the dock, the roster and the self
/// bubble read as one interface once real content is behind them.
///
/// Same shape as `ui_snapshot_test.dart`: the overflow assertion runs
/// everywhere, including CI; the PNGs are only written under
/// `SLIMM_CANVAS_ASSEMBLED=1`, since Skia rasterises differently off this
/// box. Write them with `SLIMM_CANVAS_ASSEMBLED=1 flutter test
/// test/visual/canvas_assembled_snapshot_test.dart` from `client/packages/app`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../ui_snapshot_support.dart' show loadRealFonts;
import 'canvas_assembled_gap_scenarios.dart';
import 'canvas_assembled_scene.dart';
import 'canvas_assembled_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);
  // The canvas toolbar reads SharedPreferences, a platform channel with no host here.
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  // States the scenes below never reach: registered from canvas_assembled_gap_scenarios.dart.
  registerCanvasErrorBanners();
  registerCanvasLoading();
  registerCanvasToolSelection();
  registerCanvasOverflowMenuOpen();
  registerCanvasActivityLogOpen();
  registerCanvasClearConfirm();
  registerCanvasTileControlsRevealed();

  group(
    'busy: a live call, a busy canvas, a sixth silent cursor-only reader',
    () {
      for (final theme in canvasAssembledThemes.keys) {
        for (final width in canvasAssembledWidths.entries) {
          testWidgets('${width.key} ($theme)', (tester) async {
            final image = await tester.runAsync(
              () => buildGradientImage(
                200,
                150,
                const Color(0xFF3F6FA8),
                const Color(0xFF8FC1E0),
              ),
            );
            final document = buildBusyDocument(hydratedImage: image);
            addTearDown(document.dispose);
            final cursors = buildBusyCursors();
            addTearDown(cursors.dispose);

            await renderCanvasAssembledPane(
              tester,
              name: 'busy-${width.key}-$theme',
              width: width.value,
              theme: theme,
              document: document,
              participants: busyParticipants,
              cursors: cursors,
            );
          });
        }
      }
    },
  );

  group('quiet: the same canvas, nobody on a call and no cursor moving', () {
    for (final theme in canvasAssembledThemes.keys) {
      testWidgets('desktop-1400 ($theme)', (tester) async {
        final document = buildBusyDocument();
        addTearDown(document.dispose);

        await renderCanvasAssembledPane(
          tester,
          name: 'quiet-desktop-1400-$theme',
          width: 1400,
          theme: theme,
          document: document,
        );
      });
    }
  });

  group('empty: no call, no cursor, nothing drawn yet', () {
    for (final theme in canvasAssembledThemes.keys) {
      for (final width in const ['phone-390', 'desktop-1400']) {
        testWidgets('$width ($theme)', (tester) async {
          final document = buildEmptyDocument();
          addTearDown(document.dispose);

          await renderCanvasAssembledPane(
            tester,
            name: 'empty-$width-$theme',
            width: canvasAssembledWidths[width] ?? 1400,
            theme: theme,
            document: document,
          );
        });
      }
    }
  });

  testWidgets('busy phone-390 with an object selected, dark', (tester) async {
    final document = buildBusyDocument();
    addTearDown(document.dispose);
    final cursors = buildBusyCursors();
    addTearDown(cursors.dispose);

    await renderCanvasAssembledPane(
      tester,
      name: 'busy-phone-390-selected-dark',
      width: 390,
      theme: 'dark',
      document: document,
      participants: busyParticipants,
      cursors: cursors,
      selectedObjectId: 'box-cluster',
    );
  });

  testWidgets('busy phone landscape (844x390), dark', (tester) async {
    final document = buildBusyDocument();
    addTearDown(document.dispose);
    final cursors = buildBusyCursors();
    addTearDown(cursors.dispose);

    await renderCanvasAssembledPane(
      tester,
      name: 'busy-phone-landscape-dark',
      width: 844,
      height: 390,
      theme: 'dark',
      document: document,
      participants: busyParticipants,
      cursors: cursors,
    );
  });

  testWidgets(
    'busy desktop-1400 with a tile dragged, a tile resized, and a screen '
    'share tile alongside a locked camera, dark',
    (tester) async {
      final document = buildBusyDocument();
      addTearDown(document.dispose);
      final cursors = buildBusyCursors();
      addTearDown(cursors.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      // Priya's camera dragged well clear of the top-left row and shrunk small; Jordan's camera locked in place over on the right - the owner's own "make the screen as big or small as you want... lock it in place" ask, rendered rather than reasoned about.
      overrides.setRect(
        'camera:user-priya',
        const Rect.fromLTWH(900, 620, 110, 90),
      );
      overrides.setRect(
        'camera:user-jordan',
        const Rect.fromLTWH(1180, 60, 160, 120),
      );
      overrides.setLocked('camera:user-jordan', true);

      await renderCanvasAssembledPane(
        tester,
        name: 'busy-desktop-1400-tiles-manipulated-dark',
        width: 1400,
        theme: 'dark',
        document: document,
        participants: busyParticipantsSharing,
        cursors: cursors,
        tileOverrides: overrides,
      );
    },
  );

  testWidgets(
    'busy desktop-1400 with a tile locked and sent to the back, so real ink '
    'lands on top of it, dark',
    (tester) async {
      final document = buildBusyDocument();
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      // Avery's camera sits at its own default position, which buildBusyDocument's own doc already says overlaps the box-cluster ink - the case send-to-back exists for.
      overrides.setLocked('camera:user-avery', true);
      overrides.setSentToBack('camera:user-avery', true);

      await renderCanvasAssembledPane(
        tester,
        name: 'busy-desktop-1400-tile-sent-to-back-dark',
        width: 1400,
        theme: 'dark',
        document: document,
        participants: busyParticipants,
        tileOverrides: overrides,
      );
    },
  );

  group('fullscreen: the chrome dropped, the call controls kept', () {
    for (final width in const ['phone-390', 'desktop-1400']) {
      testWidgets('$width (dark)', (tester) async {
        final document = buildBusyDocument();
        addTearDown(document.dispose);
        final cursors = buildBusyCursors();
        addTearDown(cursors.dispose);

        await renderCanvasAssembledPane(
          tester,
          name: 'fullscreen-$width-dark',
          width: canvasAssembledWidths[width] ?? 1400,
          theme: 'dark',
          document: document,
          participants: busyParticipants,
          cursors: cursors,
          fullscreen: true,
          // What entering actually arms, so the capture shows the real mode rather than a pen the dock no longer offers a way to change.
          tool: CanvasTool.pan,
        );
      });
    }
  });

  testWidgets('busy phone-390 with the truncation banner, dark', (
    tester,
  ) async {
    final document = buildBusyDocument();
    addTearDown(document.dispose);
    final cursors = buildBusyCursors();
    addTearDown(cursors.dispose);

    await renderCanvasAssembledPane(
      tester,
      name: 'busy-phone-390-truncated-dark',
      width: 390,
      theme: 'dark',
      document: document,
      participants: busyParticipants,
      cursors: cursors,
      truncated: true,
    );
  });
}
