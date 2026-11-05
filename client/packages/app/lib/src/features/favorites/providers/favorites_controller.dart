// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own favorites: GIFs and media kept from messages.
///
/// Held for the session and mutated optimistically, because the server is the
/// only source of order and availability but a reorder should not wait on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../ids.dart';
import '../../../providers/providers.dart';

final favoritesProvider =
    AsyncNotifierProvider<FavoritesController, List<api.Favorite>>(
      FavoritesController.new,
    );

class FavoritesController extends AsyncNotifier<List<api.Favorite>> {
  @override
  Future<List<api.Favorite>> build() => ref.watch(apiProvider).listFavorites();

  /// Favorites a live GIF result; a failure is thrown for the caller to show.
  Future<void> addGif(String gifId) async {
    final added = await ref
        .read(apiProvider)
        .addGifFavorite(newFavoriteId(), gifId: gifId);
    _putFirst(added);
  }

  /// Favorites an image or video on a message; a failure is thrown.
  Future<void> addAttachment({
    required String messageId,
    required String attachmentId,
  }) async {
    final added = await ref
        .read(apiProvider)
        .addAttachmentFavorite(
          newFavoriteId(),
          messageId: messageId,
          attachmentId: attachmentId,
        );
    _putFirst(added);
  }

  void _putFirst(api.Favorite added) {
    final rest = (state.valueOrNull ?? const <api.Favorite>[]).where(
      (f) => f.id != added.id,
    );
    state = AsyncData([added, ...rest]);
  }

  Future<void> remove(String id) async {
    final before = state.valueOrNull ?? const <api.Favorite>[];
    state = AsyncData(before.where((f) => f.id != id).toList());
    try {
      await ref.read(apiProvider).removeFavorite(id);
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }

  /// Moves the entry at [from] to index [to] in the current list.
  Future<void> move(int from, int to) async {
    final before = state.valueOrNull ?? const <api.Favorite>[];
    if (from == to || from < 0 || from >= before.length) return;
    final next = [...before];
    next.insert(to.clamp(0, next.length - 1), next.removeAt(from));
    state = AsyncData(next);
    try {
      await ref.read(apiProvider).reorderFavorites([
        for (final f in next) f.id,
      ]);
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }
}
