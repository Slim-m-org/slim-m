// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edit history of one message, fetched on demand for the sheet the
/// "edited" marker opens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// Names the message a history fetch is for. A record so the family key
/// compares by value, and two rows editing at once do not share a fetch.
typedef EditHistoryKey = ({String channelId, String messageId});

/// Every version a message has held, oldest first, ending with its current
/// content. `autoDispose` so each open fetches fresh: a version added while
/// the sheet was closed must show the next time it opens.
final messageEditHistoryProvider = FutureProvider.autoDispose
    .family<List<api.MessageRevision>, EditHistoryKey>(
      (ref, key) => ref
          .watch(apiProvider)
          .getMessageHistory(key.channelId, key.messageId),
    );
