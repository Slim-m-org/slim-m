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

/// Keeps the pictures fetched while a page that watches it is open.
class SpaceThemePictureHold {
  final _links = <KeepAliveLink>[];
  var _released = false;

  void _keep(KeepAliveLink link) => _released ? link.close() : _links.add(link);

  void _release() {
    _released = true;
    for (final link in _links) {
      link.close();
    }
    _links.clear();
  }
}

/// Watched by a page of lazily built cards, so a card that scrolls away and
/// back neither fetches nor decodes its picture again.
final spaceThemePictureHoldProvider =
    Provider.autoDispose<SpaceThemePictureHold>((ref) {
      final hold = SpaceThemePictureHold();
      ref.onDispose(hold._release);
      return hold;
    });

/// A store theme's picture bytes, fetched once per id.
final spaceThemePictureProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, id) async {
      final link = ref.keepAlive();
      // Read, not watched: only a page's own watch decides how long it stays.
      ref.read(spaceThemePictureHoldProvider)._keep(link);
      try {
        final fetched = await ref.watch(apiProvider).fetchSpaceThemePicture(id);
        return fetched.bytes;
      } catch (_) {
        link.close();
        rethrow;
      }
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
