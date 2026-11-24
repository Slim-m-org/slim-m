// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The paged invite list behind the invites screen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'providers.dart';

/// The invites loaded so far, newest first, and whether the server has more.
class InviteList {
  const InviteList(this.items, {this.hasMore = false, this.moreFailed = false});

  final List<api.Invite> items;
  final bool hasMore;

  /// The last "load more" failed; the list keeps what it had.
  final bool moreFailed;
}

/// Invites per request, matching the server's default page.
const invitePageSize = 50;

class InvitesNotifier extends AutoDisposeAsyncNotifier<InviteList> {
  bool _loadingMore = false;
  int _generation = 0;

  @override
  Future<InviteList> build() async {
    _generation++;
    _loadingMore = false;
    final page = await ref
        .watch(apiProvider)
        .listInvites(limit: invitePageSize);
    return InviteList(page, hasMore: page.length >= invitePageSize);
  }

  Future<void> loadMore() async {
    final start = state.valueOrNull;
    if (_loadingMore ||
        start == null ||
        !start.hasMore ||
        start.items.isEmpty) {
      return;
    }
    _loadingMore = true;
    final generation = _generation;
    try {
      final page = await ref
          .read(apiProvider)
          .listInvites(limit: invitePageSize, before: start.items.last.code);
      if (generation != _generation) return;
      final current = state.valueOrNull ?? start;
      final known = {for (final invite in current.items) invite.code};
      state = AsyncData(
        InviteList([
          ...current.items,
          for (final invite in page)
            if (!known.contains(invite.code)) invite,
        ], hasMore: page.length >= invitePageSize),
      );
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'load more invites', e, stack);
      if (generation != _generation) return;
      state = AsyncData(
        InviteList(
          (state.valueOrNull ?? start).items,
          hasMore: true,
          moreFailed: true,
        ),
      );
    } finally {
      if (generation == _generation) _loadingMore = false;
    }
  }
}

final invitesProvider =
    AsyncNotifierProvider.autoDispose<InvitesNotifier, InviteList>(
      InvitesNotifier.new,
    );
