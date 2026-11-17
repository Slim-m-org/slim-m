// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the theme store and the theme file do: apply, publish, remove, set default.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../background/providers/app_background_controller.dart';
import '../../../providers/providers.dart';
import 'background_from_theme.dart';
import 'recent_themes.dart';
import 'stored_theme.dart';
import 'theme_source.dart';
import 'theme_store.dart';

/// Makes a built-in [choice], or following the Space default, the theme in use.
Future<void> applyThemeChoice(
  ProviderContainer container,
  AppThemeChoice choice,
) async {
  final leaving = container.read(appliedThemeProvider);
  await container.read(themeControllerProvider.notifier).select(choice);
  await _recordSwitch(container, leaving, BuiltInThemeSource(choice));
}

/// The theme left behind was in use until now, so it is the most recent
/// after the new one, and going back to it is one tap.
Future<void> _recordSwitch(
  ProviderContainer container,
  AppliedTheme leaving,
  ThemeSource source, {
  ThemeDocument? theme,
}) async {
  final recent = container.read(recentThemesProvider.notifier);
  await recent.record(leaving.source, theme: leaving.document);
  await recent.record(source, theme: theme);
}

/// Makes [document] the theme in use here, recorded as coming from [source];
/// its picture, when [pictureBytes] are given, becomes the personal background
/// with the file's settings, unless [background] is false.
Future<void> applyThemeDocument(
  ProviderContainer container,
  ThemeDocument document, {
  required ThemeSource source,
  Uint8List? pictureBytes,
  bool background = true,
}) async {
  final leaving = container.read(appliedThemeProvider);
  await container.read(customThemeProvider.notifier).set(document);
  await container.read(customThemeSourceProvider.notifier).set(source);
  await container
      .read(themeControllerProvider.notifier)
      .select(AppThemeChoice.custom);
  await _recordSwitch(container, leaving, source, theme: document);
  final picture = document.picture;
  if (picture == null || pictureBytes == null || !background) return;
  final layer = container.read(appBackgroundControllerProvider.notifier);
  // The file's picture settings describe a picture that is not there, so a failed import applies none of them.
  if (!await layer.importPicture(pictureBytes)) return;
  await layer.setDim(picture.dim);
  await layer.setVignette(picture.vignette);
  await layer.setBlur(picture.blur);
  await container.read(backgroundFromThemeProvider.notifier).set(document.name);
}

/// Applies the Space theme [id], already read as [document], fetching its
/// picture first when it has one.
Future<void> applySpaceTheme(
  ProviderContainer container,
  String id,
  ThemeDocument document, {
  required bool hasPicture,
}) async {
  final bytes = hasPicture
      ? await container.read(spaceThemePictureProvider(id).future)
      : null;
  await applyThemeDocument(
    container,
    document,
    source: SpaceThemeSource(id),
    pictureBytes: bytes,
  );
}

/// Publishes [document] to the Space under the signed-in member's name.
Future<void> publishTheme(
  ProviderContainer container,
  ThemeDocument document,
) async {
  final me = container.read(meProvider).valueOrNull;
  final shown = (me?.displayName ?? me?.username ?? '').trim();
  final author = String.fromCharCodes(shown.runes.take(themeNameMaxChars));
  final file = document.copyWith(author: author, dropPicture: true);
  await container.read(apiProvider).publishSpaceTheme(file.toJson());
  container.invalidate(spaceThemesProvider);
}

Future<void> removeStoreTheme(ProviderContainer container, String id) async {
  await container.read(apiProvider).deleteSpaceTheme(id);
  container.invalidate(spaceThemesProvider);
}

/// A null [id] clears the Space default.
Future<void> setSpaceDefaultTheme(
  ProviderContainer container,
  String? id,
) async {
  await container.read(apiProvider).setSpaceDefaultTheme(id);
  container.invalidate(spaceThemesProvider);
}
