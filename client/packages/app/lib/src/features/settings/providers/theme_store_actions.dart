// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the theme store and the theme file do: apply, remove, set default.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../background/providers/app_background_controller.dart';
import '../../../providers/providers.dart';
import 'stored_theme.dart';
import 'theme_store.dart';

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
  // The file's picture settings describe a picture that is not there, so a failed import applies none of them.
  if (pictureBytes != null && !await background.importPicture(pictureBytes)) {
    return;
  }
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

Future<void> removeStoreTheme(WidgetRef ref, String id) async {
  await ref.read(apiProvider).deleteSpaceTheme(id);
  ref.invalidate(spaceThemesProvider);
}

/// A null [id] clears the Space default.
Future<void> setSpaceDefaultTheme(WidgetRef ref, String? id) async {
  await ref.read(apiProvider).setSpaceDefaultTheme(id);
  ref.invalidate(spaceThemesProvider);
}
