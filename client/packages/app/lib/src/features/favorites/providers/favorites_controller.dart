// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own favorites: GIFs and media kept from messages.
///
/// Held for the session, read again on every reconnect, and mutated optimistically, because the server is the
/// only source of order and availability but a reorder should not wait on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../ids.dart';
import '../../../providers/providers.dart';
import '../../../sync/providers/sync_status.dart';

final favoritesProvider =
    AsyncNotifierProvider<FavoritesController, List<api.Favorite>>(
      FavoritesController.new,
    );

class FavoritesController extends AsyncNotifier<List<api.Favorite>> {
  int _mutating = 0;
  bool _resyncWaiting = false;

  @override
  Future<List<api.Favorite>> build() {
    ref.listen(syncResyncProvider, (_, _) => _resync());
    return ref.watch(apiProvider).listFavorites();
  }

  /// A reconnect mid-mutation would replace the list with one fetched before the change landed, so it waits for the change.
  void _resync() {
    if (_mutating > 0) {
      _resyncWaiting = true;
      return;
    }
    ref.invalidateSelf();
  }

  Future<T> _mutation<T>(Future<T> Function() change) async {
    _mutating++;
    try {
      return await change();
    } finally {
      _mutating--;
      if (_mutating == 0 && _resyncWaiting) {
        _resyncWaiting = false;
        ref.invalidateSelf();
      }
    }
  }

  /// Favorites a live GIF result; a failure is thrown for the caller to show.
  Future<void> addGif(String gifId) => _mutation(() async {
    final added = await ref
        .read(apiProvider)
        .addGifFavorite(newFavoriteId(), gifId: gifId);
    _putFirst(added);
  });

  /// Favorites an image or video on a message; a failure is thrown.
  Future<void> addAttachment({
    required String messageId,
    required String attachmentId,
  }) => _mutation(() async {
    final added = await ref
        .read(apiProvider)
        .addAttachmentFavorite(
          newFavoriteId(),
          messageId: messageId,
          attachmentId: attachmentId,
        );
    _putFirst(added);
  });

  /// A list that never loaded is fetched again rather than replaced by the one
  /// favorite just added, which would hide every other.
  void _putFirst(api.Favorite added) {
    final current = state.valueOrNull;
    if (current == null) {
      ref.invalidateSelf();
      return;
    }
    state = AsyncData([added, ...current.where((f) => f.id != added.id)]);
  }

  /// A failure puts back only this entry, so a change made meanwhile stays.
  Future<void> remove(String id) => _mutation(() async {
    final current = state.valueOrNull ?? const <api.Favorite>[];
    final index = current.indexWhere((f) => f.id == id);
    if (index >= 0) state = AsyncData([...current]..removeAt(index));
    try {
      await ref.read(apiProvider).removeFavorite(id);
    } catch (_) {
      if (index >= 0) _putBack(current[index], index);
      rethrow;
    }
  });

  /// Moves the entry at [from] to index [to] in the current list.
  Future<void> move(int from, int to) => _mutation(() async {
    final before = state.valueOrNull ?? const <api.Favorite>[];
    if (from == to || from < 0 || from >= before.length) return;
    final moved = before[from];
    final next = [...before];
    next.insert(to.clamp(0, next.length - 1), next.removeAt(from));
    state = AsyncData(next);
    try {
      await ref.read(apiProvider).reorderFavorites([
        for (final f in next) f.id,
      ]);
    } catch (_) {
      // One removed in the meantime stays gone.
      if (_ids().contains(moved.id)) _putBack(moved, from);
      rethrow;
    }
  });

  Set<String> _ids() => {
    for (final f in state.valueOrNull ?? const <api.Favorite>[]) f.id,
  };

  /// Places [favorite] at [index], taking it from wherever it sits now.
  void _putBack(api.Favorite favorite, int index) {
    final current = state.valueOrNull ?? const <api.Favorite>[];
    final rest = current.where((f) => f.id != favorite.id).toList();
    state = AsyncData(rest..insert(index.clamp(0, rest.length), favorite));
  }
}
