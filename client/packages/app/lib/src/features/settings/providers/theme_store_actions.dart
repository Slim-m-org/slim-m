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
Future<void> applyThemeChoice(WidgetRef ref, AppThemeChoice choice) async {
  final leaving = ref.read(appliedThemeProvider);
  await ref.read(themeControllerProvider.notifier).select(choice);
  await _recordSwitch(ref, leaving, BuiltInThemeSource(choice));
}

/// The theme left behind was in use until now, so it is the most recent
/// after the new one, and going back to it is one tap.
Future<void> _recordSwitch(
  WidgetRef ref,
  AppliedTheme leaving,
  ThemeSource source, {
  ThemeDocument? theme,
}) async {
  final recent = ref.read(recentThemesProvider.notifier);
  await recent.record(leaving.source, theme: leaving.document);
  await recent.record(source, theme: theme);
}

/// Makes [document] the theme in use here, recorded as coming from [source];
/// its picture, when [pictureBytes] are given, becomes the personal background
/// with the file's settings, unless [background] is false.
Future<void> applyThemeDocument(
  WidgetRef ref,
  ThemeDocument document, {
  required ThemeSource source,
  Uint8List? pictureBytes,
  bool background = true,
}) async {
  final leaving = ref.read(appliedThemeProvider);
  await ref.read(customThemeProvider.notifier).set(document);
  await ref.read(customThemeSourceProvider.notifier).set(source);
  await ref
      .read(themeControllerProvider.notifier)
      .select(AppThemeChoice.custom);
  await _recordSwitch(ref, leaving, source, theme: document);
  final picture = document.picture;
  if (picture == null || !background) return;
  final layer = ref.read(appBackgroundControllerProvider.notifier);
  // The file's picture settings describe a picture that is not there, so a failed import applies none of them.
  if (pictureBytes != null && !await layer.importPicture(pictureBytes)) {
    return;
  }
  await layer.setDim(picture.dim);
  await layer.setVignette(picture.vignette);
  await layer.setBlur(picture.blur);
  await ref.read(backgroundFromThemeProvider.notifier).set(document.name);
}

Future<void> applyStoreTheme(WidgetRef ref, api.SpaceTheme theme) async {
  final document = parseThemeJson(theme.theme).document;
  if (document == null) return;
  await applySpaceTheme(ref, theme.id, document, hasPicture: theme.hasPicture);
}

/// Applies the Space theme [id], already read as [document], fetching its
/// picture first when it has one.
Future<void> applySpaceTheme(
  WidgetRef ref,
  String id,
  ThemeDocument document, {
  required bool hasPicture,
}) async {
  final bytes = hasPicture
      ? await ref.read(spaceThemePictureProvider(id).future)
      : null;
  await applyThemeDocument(
    ref,
    document,
    source: SpaceThemeSource(id),
    pictureBytes: bytes,
  );
}

/// Publishes [document] to the Space under the signed-in member's name.
Future<void> publishTheme(WidgetRef ref, ThemeDocument document) async {
  final me = ref.read(meProvider).valueOrNull;
  final shown = (me?.displayName ?? me?.username ?? '').trim();
  final author = String.fromCharCodes(shown.runes.take(themeNameMaxChars));
  final file = document.copyWith(author: author, dropPicture: true);
  await ref.read(apiProvider).publishSpaceTheme(file.toJson());
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
