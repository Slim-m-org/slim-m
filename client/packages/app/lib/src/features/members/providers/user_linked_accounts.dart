// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The accounts a member linked, for their profile card.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

/// Fetched when a card opens, like [userNoteProvider]'s per-subject fetch. A
/// failure reads as no links: the row is a nicety, not worth an error state.
final userLinkedAccountsProvider = FutureProvider.autoDispose
    .family<List<LinkedAccount>, String>((ref, userId) async {
      try {
        return await ref.watch(apiProvider).linkedAccountsOf(userId);
      } on ApiException {
        return const [];
      }
    });
