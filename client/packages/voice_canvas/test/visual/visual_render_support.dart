// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rasterising a canvas scene straight to a PNG, with no widget mounted at
/// all: a plain `test()`, a `ui.PictureRecorder`, and a file write.
///
/// This is the technique a previous design pass used to get real pixels out
/// of these painters without going through `testWidgets` at all, since the
/// full canvas pane is known to hang a widget test on a loaded box. Nothing
/// here pumps a frame or touches `WidgetTester`.
///
/// **Every PNG this writes is rasterised in software** (`flutter test` has
/// no GPU), which can paint a thin diagonal stroke as broken or dotted at
/// a low effective pixel width even when the geometry is correct; see
/// `docs/DEVELOPING.md` before reading `zoom_stress_0.25x.png` as a real gap.
///
/// A soft shadow still blurs here, because this file never builds the
/// `AutomatedTestWidgetsFlutterBinding` that sets `debugDisableShadows`. The
/// app package's snapshot tests do, and `support/real_shadows.dart` there
/// turns it back off.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Set to write PNGs; unset, every scene still runs (so a regression in the
/// painters themselves still throws) but nothing is written to disk.
bool get writingVisuals => Platform.environment['SLIMM_CANVAS_VISUAL'] == '1';

const visualOutDir = 'build/canvas-visual';

/// Pixel comparison only where the reference images were produced, as in design_system's golden matrix.
const bool comparingGoldens = bool.fromEnvironment('SLIMM_GOLDENS');

/// The real IBM Plex faces, loaded by hand from the sibling design_system
/// package - by path, not by pub dependency, since this package deliberately
/// carries none. Without this every glyph in a rendered note or cursor label
/// draws as a filled box, which would make the very thing under review
/// unreadable rather than merely unstyled.
Future<void> loadVisualFonts() async {
  const design = '../design_system/fonts';
  await _loadFamily('IBM Plex Sans Visual', [
    '$design/IBMPlexSans-Regular.ttf',
    '$design/IBMPlexSans-Medium.ttf',
  ]);
}

Future<void> _loadFamily(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
}

/// The one family name every visual scene's text uses, once loaded.
const visualSansFamily = 'IBM Plex Sans Visual';

/// Paints [draw] onto a fresh `width`x`height` surface and writes it as
/// `$visualOutDir/$name.png`, unless [writingVisuals] is false.
///
/// Runs the paint callback regardless of [writingVisuals], so a painter
/// throwing (a real regression) still fails the test even when nobody asked
/// for the pixels.
Future<void> renderVisualScene(
  String name,
  int width,
  int height,
  void Function(Canvas canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  draw(canvas);
  final picture = recorder.endRecording();
  if (!writingVisuals && !comparingGoldens) {
    picture.dispose();
    return;
  }
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final png = bytes!.buffer.asUint8List();
  if (comparingGoldens) {
    await expectLater(png, matchesGoldenFile('../goldens/$name.png'));
  }
  if (!writingVisuals) return;
  Directory(visualOutDir).createSync(recursive: true);
  File('$visualOutDir/$name.png').writeAsBytesSync(png);
}
