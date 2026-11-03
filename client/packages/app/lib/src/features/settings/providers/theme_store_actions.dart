// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the theme store and the theme file do: apply, export, import, publish.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../background/providers/app_background_controller.dart';
import '../../background/providers/background_image_store.dart';
import '../../background/providers/background_tone.dart';
import '../../../providers/providers.dart';
import 'theme_labels.dart';
import 'resolved_theme.dart';
import 'stored_theme.dart';
import 'theme_store.dart';

const _exportSides = [1280, 800];

/// Makes [document] the theme in use here; its picture, when [pictureBytes]
/// are given, becomes the personal background with the file's settings.
Future<void> applyThemeDocument(
  WidgetRef ref,
  ThemeDocument document, {
  Uint8List? pictureBytes,
}) async {
  await ref.read(customThemeProvider.notifier).set(document);
  await ref
      .read(themeControllerProvider.notifier)
      .select(AppThemeChoice.custom);
  final picture = document.picture;
  if (picture == null) return;
  final background = ref.read(appBackgroundControllerProvider.notifier);
  if (pictureBytes != null) await background.importPicture(pictureBytes);
  await background.setDim(picture.dim);
  await background.setVignette(picture.vignette);
  await background.setBlur(picture.blur);
}

Future<void> applyStoreTheme(WidgetRef ref, api.SpaceTheme theme) async {
  final document = parseThemeJson(theme.theme).document;
  if (document == null) return;
  Uint8List? bytes;
  if (theme.hasPicture) {
    bytes = await ref.read(spaceThemePictureProvider(theme.id).future);
  }
  await applyThemeDocument(ref, document, pictureBytes: bytes);
}

/// The theme in use, as a file: its colours, backdrop effect and, when one is
/// set, the personal background picture shrunk to fit the 2 MiB cap.
Future<ThemeDocument> currentThemeDocument(
  WidgetRef ref,
  Brightness brightness,
) async {
  final choice = ref.read(themeControllerProvider);
  final custom = ref.read(customThemeProvider);
  final space = ref.read(spaceDefaultThemeProvider);
  final resolved = resolveTheme(choice, custom: custom, spaceDefault: space);
  final tokens = brightness == Brightness.light
      ? resolved.light
      : resolved.dark;
  final stored = switch (choice) {
    AppThemeChoice.custom => custom,
    AppThemeChoice.spaceDefault => space,
    _ => null,
  };
  final me = await _me(ref);
  return ThemeDocument.of(
    tokens,
    name: stored?.name ?? '${themeLabel(choice)} copy',
    author: me?.displayName ?? '',
    base: stored?.base ?? _baseFor(choice, brightness),
    brightness: brightness,
    picture: await _backgroundPicture(ref),
  );
}

Future<api.Me?> _me(WidgetRef ref) async {
  try {
    return await ref.read(meProvider.future);
  } catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.ui,
      'Exported a theme without the author name',
      error,
      stack,
    );
    return null;
  }
}

String _baseFor(AppThemeChoice choice, Brightness brightness) =>
    switch (choice) {
      AppThemeChoice.trueBlack => 'trueBlack',
      AppThemeChoice.catppuccin => 'catppuccin',
      AppThemeChoice.softDark => 'softDark',
      AppThemeChoice.forest => 'forest',
      AppThemeChoice.halloween => 'halloween',
      AppThemeChoice.light => 'light',
      _ => brightness == Brightness.light ? 'light' : 'dark',
    };

Future<ThemePicture?> _backgroundPicture(WidgetRef ref) async {
  final settings = ref.read(appBackgroundControllerProvider);
  if (!settings.hasImage) return null;
  final source = await ref.read(backgroundImageStoreProvider).read();
  if (source == null) return null;
  for (final side in _exportSides) {
    final prepared = await prepareBackground(
      source,
      maxSide: side,
      maxSourcePixels: backgroundMaxSourcePixels,
    );
    if (prepared != null && prepared.png.length <= themePictureMaxBytes) {
      return ThemePicture(
        dim: settings.dim,
        vignette: settings.vignette,
        blur: settings.blur,
        data: prepared.png,
      );
    }
  }
  return null;
}

/// False when the person cancelled the save.
Future<bool> saveThemeFile(ThemeDocument document) async {
  final name = document.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  final saved = await FilePicker.saveFile(
    fileName: '$name.slimm-theme.json',
    bytes: Uint8List.fromList(utf8.encode(document.toJsonText())),
  );
  return saved != null;
}

/// Opens the file picker; a seam so a test can hand over a file.
final themeFilePickerProvider = Provider<Future<ThemeParse?> Function()>(
  (ref) => pickThemeFile,
);

/// Null when the person cancelled the picker.
Future<ThemeParse?> pickThemeFile() async {
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  if (picked == null) return null;
  final bytes = await picked.readAsBytes();
  if (bytes.length > themePictureMaxBytes * 2) {
    return const ThemeParse.failed(['The file is too large for a theme.']);
  }
  return parseThemeFile(utf8.decode(bytes, allowMalformed: true));
}

Future<void> publishThemeDocument(WidgetRef ref, ThemeDocument document) async {
  await ref.read(apiProvider).publishSpaceTheme(document.toJson());
  ref.invalidate(spaceThemesProvider);
}

Future<void> removeStoreTheme(WidgetRef ref, String id) async {
  await ref.read(apiProvider).deleteSpaceTheme(id);
  ref.invalidate(spaceThemesProvider);
}

/// A null [id] clears the Space default.
Future<void> setSpaceDefaultTheme(WidgetRef ref, String? id) async {
  await ref.read(apiProvider).setSpaceDefaultTheme(id);
  ref.invalidate(spaceThemesProvider);
}
