// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's theme store: the list, each theme's picture, and keeping a
/// local copy of the Space default so it applies before the first request.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import 'stored_theme.dart';

final spaceThemesProvider = FutureProvider.autoDispose<api.SpaceThemeList>(
  (ref) => ref.watch(apiProvider).listSpaceThemes(),
);

/// A store theme's picture bytes, fetched once per id.
final spaceThemePictureProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, id) async {
      final fetched = await ref.watch(apiProvider).fetchSpaceThemePicture(id);
      return fetched.bytes;
    });

/// Mirrors the Space default into [spaceDefaultThemeProvider] whenever the
/// store loads, and clears it when the Space has none. Watched by the app.
final spaceThemeSyncProvider = Provider<void>((ref) {
  if (ref.watch(sessionProvider).tokens == null) return;
  final list = ref.watch(spaceThemesProvider).valueOrNull;
  if (list == null) return;
  final id = list.defaultThemeId;
  final match = list.themes.where((t) => t.id == id).firstOrNull;
  final document = match == null ? null : parseThemeJson(match.theme).document;
  final stored = ref.read(spaceDefaultThemeProvider.notifier);
  Future.microtask(() => stored.set(document));
});
