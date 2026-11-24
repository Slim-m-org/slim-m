// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real faces every snapshot harness loads by hand.
///
/// Split out of `ui_snapshot_support.dart` when the colour emoji lookup
/// pushed that file past the 500-line ceiling; every symbol here is
/// re-exported from it, so no call site had to change.
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// The real faces, loaded by hand.
///
/// Without this the test binding draws every glyph as a filled box and every
/// icon as an empty square, which reads as a layout bug in the PNG rather
/// than as a missing font.
///
/// [pubCacheOverride] exists only so a test can point the Lucide lookup at a
/// directory that cannot resolve, without touching the real `PUB_CACHE`.
Future<void> loadRealFonts({String? pubCacheOverride}) async {
  const design = '../design_system';
  await loadFontFamily('packages/slimm_design_system/IBM Plex Sans', [
    '$design/fonts/IBMPlexSans-Regular.ttf',
    '$design/fonts/IBMPlexSans-Medium.ttf',
    '$design/fonts/IBMPlexSans-SemiBold.ttf',
  ]);
  await loadFontFamily('packages/slimm_design_system/IBM Plex Mono', [
    '$design/fonts/IBMPlexMono-Regular.ttf',
    '$design/fonts/IBMPlexMono-Medium.ttf',
  ]);

  final cache = pubCacheOverride ?? _pubCache();
  final lucideDir = '$cache/lucide_icons_flutter-${_lucideVersion()}';
  await loadFontFamily('packages/lucide_icons_flutter/Lucide', [
    '$lucideDir/assets/lucide.ttf',
  ]);
  // AppIcons uses the 1.5-stroke variants, which live on their own family.
  await loadFontFamily('packages/lucide_icons_flutter/Lucide300', [
    '$lucideDir/assets/build_font/LucideVariable-w300.ttf',
  ]);
  // The presence marks (phone, left, deleted) use the heavier 500 stroke.
  await loadFontFamily('packages/lucide_icons_flutter/Lucide500', [
    '$lucideDir/assets/build_font/LucideVariable-w500.ttf',
  ]);
  // A bare Scaffold's default BackButton reaches Icons.arrow_back, not AppIcons.
  await loadFontFamily('MaterialIcons', [
    'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
  ]);
  await loadEmojiFont();
}

/// The paths a colour emoji face is actually installed at, most specific
/// first: Fedora's own packaging, then Debian and Ubuntu's, then the two
/// layouts other distributions use.
const _emojiFontPaths = [
  '/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf',
  '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
  '/usr/share/fonts/google-noto-color-emoji/NotoColorEmoji.ttf',
  '/usr/share/fonts/noto-color-emoji/NotoColorEmoji.ttf',
  '/usr/share/fonts/TTF/NotoColorEmoji.ttf',
];

/// The first colour emoji face installed on this machine, or null when none
/// of [_emojiFontPaths] resolves.
String? emojiFontPath({List<String>? pathsOverride}) {
  for (final path in pathsOverride ?? _emojiFontPaths) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Loads the colour emoji face [AppFonts.emoji] names first, so a reaction
/// chip renders as the emoji somebody actually reacted with.
///
/// Emoji are user content here rather than chrome, so a render that drops
/// them is not a cosmetic gap: every reaction, and every message carrying
/// one, comes out as a row of tofu boxes, and a reviewer reading those
/// screenshots reports a defect the product does not have. This is the same
/// trap `loadFontFamily`'s own doc names for a repo asset, one layer out.
///
/// Unlike every other family here it is a *system* font rather than a file
/// this repo ships, so it is looked up across the paths distributions
/// actually use, and its absence is warned about rather than thrown on: a
/// runner without one can still render everything else truthfully, and a
/// silent skip is what would put us back to boxes with nothing saying so.
Future<void> loadEmojiFont({List<String>? pathsOverride}) async {
  final found = emojiFontPath(pathsOverride: pathsOverride);
  if (found != null) {
    await loadFontFamily('Noto Color Emoji', [found]);
    return;
  }
  stderr.writeln(
    'ui-capture: no colour emoji font found, so every emoji in these '
    'renders will be a tofu box. Looked in: '
    '${(pathsOverride ?? _emojiFontPaths).join(', ')}',
  );
}

/// Loads one font family, letting a missing asset throw rather than
/// rendering that family's glyphs as boxes with nothing in the run saying so.
Future<void> loadFontFamily(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
}

/// `PUB_CACHE`, when set, names the cache root, not the `hosted/pub.dev`
/// package directory beneath it, so both branches resolve to that same depth.
String _pubCache() {
  final override = Platform.environment['PUB_CACHE'];
  if (override != null) return '$override/hosted/pub.dev';
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.pub-cache/hosted/pub.dev';
}

/// Read from the lockfile rather than pinned here, so a bump does not
/// silently drop back to square icons.
///
/// Throws rather than returning an empty version on a miss: a silent '' used
/// to resolve to a directory named `lucide_icons_flutter-` that never exists,
/// which read as a missing-font failure with no hint the version scan failed.
String _lucideVersion() {
  final lock = File('../../pubspec.lock');
  final lines = lock.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() != 'lucide_icons_flutter:') continue;
    for (var j = i + 1; j < lines.length && lines[j].startsWith('    '); j++) {
      final match = RegExp(r'version:\s*"?([^"\s]+)"?').firstMatch(lines[j]);
      if (match != null) return match.group(1)!;
    }
    break;
  }
  throw StateError(
    'lucide_icons_flutter has no version line in ../../pubspec.lock',
  );
}
