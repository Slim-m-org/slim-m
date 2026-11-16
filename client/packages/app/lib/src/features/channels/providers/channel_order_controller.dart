// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Setting the deployment's channel order and category placement from the
/// rail: `PUT /channels/order` ([api.SlimmApiChannelAdmin.reorderChannels]).
/// [CategoryOrderController] below is the category sibling.
///
/// Optimistic, the same shape `BlocksController.block` uses: the new
/// arrangement renders the instant a drag completes, and the round trip only
/// decides whether it sticks. The local store is never rewritten ahead of
/// the server's answer - `pendingOrder` is what the rail renders meanwhile,
/// because the server is what assigns the real position values, and every
/// other client with this rail open has to agree on the same ones.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show CategoryStore;

import '../../../api_failure.dart';
import '../../../providers/providers.dart';
import 'category_nesting.dart';

/// A store or parse failure has no API wording, and its raw text is a log line.
String _failureMessage(String whatFailed, Object e) => e is api.ApiException
    ? describeApiFailure(whatFailed, e)
    : 'Could not $whatFailed.';

/// What the rail should show while a reorder is in flight or has failed.
class ChannelOrderState {
  const ChannelOrderState({this.pendingOrder, this.error});

  /// The whole rail, grouped by category, this client asked for and has not
  /// yet heard confirmed or refused. Null once the request settles either
  /// way: on success the local store already holds the confirmed
  /// arrangement, and on failure the rail falls back to showing what it had
  /// before this attempt.
  final List<api.ChannelOrderGroup>? pendingOrder;

  /// What to show if the last attempt failed, or null.
  final String? error;
}

class ChannelOrderController extends StateNotifier<ChannelOrderState> {
  ChannelOrderController(this._ref) : super(const ChannelOrderState());

  final Ref _ref;
  List<api.ChannelOrderGroup>? _lastAttempt;

  /// Bumped by every [reorder] call, so a response arriving after a newer
  /// drag has already superseded it is dropped rather than applying a stale
  /// arrangement over the store or clearing `pendingOrder` out from under a
  /// still-in-flight newer attempt. The same shape `BlocksController`'s
  /// session-race fix uses.
  int _generation = 0;

  /// Submits [groups] - the whole rail, grouped by category, in the
  /// arrangement a drag produced - and renders it immediately. A channel of
  /// any kind may be named in any group: a category decides placement only,
  /// never behaviour (docs/decisions/0006-channel-categories.md).
  Future<void> reorder(List<api.ChannelOrderGroup> groups) async {
    _lastAttempt = groups;
    final generation = ++_generation;
    state = ChannelOrderState(pendingOrder: groups);
    try {
      final updated = await _ref.read(apiProvider).reorderChannels(groups);
      if (!mounted || generation != _generation) return;
      final store = await _ref.read(storeProvider.future);
      if (!mounted || generation != _generation) return;
      await store.upsertChannels(updated);
      if (!mounted || generation != _generation) return;
      state = const ChannelOrderState();
    } catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'reorder channels', e, stack);
      if (!mounted || generation != _generation) return;
      state = ChannelOrderState(error: _failureMessage('reorder channels', e));
    }
  }

  /// Retries the arrangement that last failed, or does nothing if none did.
  Future<void> retry() {
    final attempt = _lastAttempt;
    return attempt == null ? Future<void>.value() : reorder(attempt);
  }

  /// Clears a failure without retrying, accepting the reverted arrangement.
  void dismiss() {
    if (mounted) state = const ChannelOrderState();
  }
}

final channelOrderControllerProvider =
    StateNotifierProvider<ChannelOrderController, ChannelOrderState>(
      (ref) => ChannelOrderController(ref),
    );

/// What the rail should show while a category arrangement is in flight or
/// has failed.
class CategoryOrderState {
  const CategoryOrderState({this.pendingOrder, this.error});

  /// The arrangement this client asked for and has not yet heard back on,
  /// which the rail draws meanwhile; null once it settles either way.
  final List<api.CategoryOrderGroup>? pendingOrder;

  final String? error;
}

/// Setting the deployment's category arrangement from the rail.
///
/// A server that nests (decision 0120) takes the whole tree in one
/// `PUT /categories/order`, so a refusal reverts cleanly. An older one only
/// has `PATCH /categories/{id}`, so [reorder] falls back to one request per
/// moved category and applies whichever succeeded before `pendingOrder`
/// clears, so what renders next is what the server actually holds.
class CategoryOrderController extends StateNotifier<CategoryOrderState> {
  CategoryOrderController(this._ref) : super(const CategoryOrderState());

  final Ref _ref;
  Future<void> Function()? _lastAttempt;

  /// See [ChannelOrderController._generation]'s own doc: the same
  /// stale-response guard, one controller over.
  int _generation = 0;

  /// Submits [groups], the whole tree as a drag or a menu step left it.
  Future<void> arrange(List<api.CategoryOrderGroup> groups) async {
    if (!_ref.read(categoriesNestProvider)) {
      return reorder(groups.firstWhere((g) => g.parentId == null).categoryIds);
    }
    _lastAttempt = () => arrange(groups);
    final generation = ++_generation;
    state = CategoryOrderState(pendingOrder: groups);
    await _settle(
      generation,
      'reorder categories',
      () => _ref.read(apiProvider).reorderCategories(groups),
    );
  }

  /// Files [categoryId] under the top-level [parentId], or at the top level
  /// for null, after its new siblings.
  Future<void> move(String categoryId, String? parentId) async {
    _lastAttempt = () => move(categoryId, parentId);
    final generation = ++_generation;
    state = const CategoryOrderState();
    await _settle(generation, 'move the category', () async {
      final moved = await _ref
          .read(apiProvider)
          .moveCategory(categoryId: categoryId, parentId: parentId);
      return [moved];
    });
  }

  Future<void> _settle(
    int generation,
    String whatFailed,
    Future<List<api.ChannelCategory>> Function() request,
  ) async {
    try {
      final updated = await request();
      if (!mounted || generation != _generation) return;
      final store = await _ref.read(storeProvider.future);
      if (!mounted || generation != _generation) return;
      for (final category in updated) {
        await store.upsertCategory(category);
      }
      if (!mounted || generation != _generation) return;
      state = const CategoryOrderState();
    } catch (e, stack) {
      api.reportFailure(api.LogTag.ui, whatFailed, e, stack);
      if (!mounted || generation != _generation) return;
      state = CategoryOrderState(error: _failureMessage(whatFailed, e));
    }
  }

  /// The older server's path: [categoryIds] are every top-level category in
  /// order, sent as positions 0..N-1, one request per changed category.
  Future<void> reorder(List<String> categoryIds) async {
    _lastAttempt = () => reorder(categoryIds);
    final generation = ++_generation;
    state = CategoryOrderState(
      pendingOrder: [
        api.CategoryOrderGroup(parentId: null, categoryIds: categoryIds),
      ],
    );
    final client = _ref.read(apiProvider);
    final moves = await _positionsToWrite(categoryIds);
    if (!mounted || generation != _generation) return;
    final succeeded = <api.ChannelCategory>[];
    api.ApiException? firstFailure;
    await Future.wait(
      moves.entries.map((move) async {
        try {
          succeeded.add(
            await client.updateCategory(
              categoryId: move.key,
              position: move.value,
            ),
          );
        } on api.ApiException catch (e, stack) {
          api.reportFailure(api.LogTag.ui, 'reorder categories', e, stack);
          firstFailure ??= e;
        }
      }),
    );
    if (!mounted || generation != _generation) return;
    Object? failure = firstFailure;
    try {
      if (succeeded.isNotEmpty) {
        final store = await _ref.read(storeProvider.future);
        if (!mounted || generation != _generation) return;
        for (final category in succeeded) {
          await store.upsertCategory(category);
        }
      }
    } catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'save the new channel order', e, stack);
      failure ??= e;
    }
    if (!mounted || generation != _generation) return;
    state = failure == null
        ? const CategoryOrderState()
        : CategoryOrderState(
            error: _failureMessage('reorder categories', failure),
          );
  }

  /// A category already at its new index needs no request: each one spends a write-class token and fans an event out to every client.
  Future<Map<String, int>> _positionsToWrite(List<String> categoryIds) async {
    final stored = <String, int>{};
    try {
      final store = await _ref.read(storeProvider.future);
      for (final row in await store.allCategories()) {
        stored[row.id] = row.position;
      }
    } catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'read the category order', e, stack);
    }
    return {
      for (final (index, id) in categoryIds.indexed)
        if (stored[id] != index) id: index,
    };
  }

  /// Retries the arrangement that last failed, or does nothing if none did.
  Future<void> retry() => _lastAttempt?.call() ?? Future<void>.value();

  /// Clears a failure without retrying, accepting whatever the store holds.
  void dismiss() {
    if (mounted) state = const CategoryOrderState();
  }
}

final categoryOrderControllerProvider =
    StateNotifierProvider<CategoryOrderController, CategoryOrderState>(
      (ref) => CategoryOrderController(ref),
    );
