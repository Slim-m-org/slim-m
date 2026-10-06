// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Setting the deployment's channel order and category placement from the
/// rail: `PUT /channels/order` ([api.SlimmApiChannelAdmin.reorderChannels]).
/// [CategoryOrderController] below is the category-reorder sibling, from the
/// categories admin screen rather than the rail.
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

import '../api_failure.dart';
import 'providers.dart';

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
    } catch (e) {
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

/// What the categories screen should show while a category reorder is in
/// flight or has failed.
class CategoryOrderState {
  const CategoryOrderState({this.pendingOrder, this.error});

  /// Every live category's id, in the arrangement this client asked for and
  /// has not yet heard back on for every one of them. Null once every
  /// request in that attempt has settled, whether or not all of them
  /// succeeded - see [CategoryOrderController.reorder]'s own doc comment for
  /// why "settled" and "succeeded" are not the same thing here.
  final List<String>? pendingOrder;

  final String? error;
}

/// Setting the deployment's channel-category order: one `PATCH
/// /categories/{id}` per category ([api.SlimmApiChannelAdmin.updateCategory]'s
/// own `position` argument), never a bulk request - categories have no
/// `PUT .../order` equivalent, only the single-row route `updateCategory`'s
/// own doc comment already names.
///
/// Same optimistic shape as [ChannelOrderController] above, with one real
/// difference: a channel reorder is one atomic request, so a refusal reverts
/// cleanly to whatever the store already held. A category reorder is N
/// independent requests, so a partial failure can leave some categories
/// repositioned and others not - [reorder] applies every response that did
/// succeed to the local store before `pendingOrder` clears, so what renders
/// next is always what the server actually holds rather than either a full
/// revert or a fiction that everything landed.
class CategoryOrderController extends StateNotifier<CategoryOrderState> {
  CategoryOrderController(this._ref) : super(const CategoryOrderState());

  final Ref _ref;
  List<String>? _lastAttempt;

  /// See [ChannelOrderController._generation]'s own doc: the same
  /// stale-response guard, one controller over.
  int _generation = 0;

  /// Submits [categoryIds] - every live category, in the arrangement a drag
  /// produced - as sequential positions 0..N-1, one request per category,
  /// run together rather than one at a time.
  Future<void> reorder(List<String> categoryIds) async {
    _lastAttempt = categoryIds;
    final generation = ++_generation;
    state = CategoryOrderState(pendingOrder: categoryIds);
    final client = _ref.read(apiProvider);
    final succeeded = <api.ChannelCategory>[];
    api.ApiException? firstFailure;
    await Future.wait(
      categoryIds.asMap().entries.map((entry) async {
        try {
          succeeded.add(
            await client.updateCategory(
              categoryId: entry.value,
              position: entry.key,
            ),
          );
        } on api.ApiException catch (e) {
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
    } catch (e) {
      failure ??= e;
    }
    if (!mounted || generation != _generation) return;
    state = failure == null
        ? const CategoryOrderState()
        : CategoryOrderState(
            error: _failureMessage('reorder categories', failure),
          );
  }

  /// Retries the arrangement that last failed, or does nothing if none did.
  Future<void> retry() {
    final attempt = _lastAttempt;
    return attempt == null ? Future<void>.value() : reorder(attempt);
  }

  /// Clears a failure without retrying, accepting whatever the store holds.
  void dismiss() {
    if (mounted) state = const CategoryOrderState();
  }
}

final categoryOrderControllerProvider =
    StateNotifierProvider<CategoryOrderController, CategoryOrderState>(
      (ref) => CategoryOrderController(ref),
    );
