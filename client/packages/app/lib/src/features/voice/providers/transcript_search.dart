// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Transcript search for the command palette (decision 0113).
library;

import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../messages/providers/message_search.dart' show ProviderReader;

/// Lines matching [query], newest first. A refusal or a failure reads as no
/// hits: the group is secondary to the messages beside it, and a server that
/// does not keep transcripts has nothing to say.
Future<List<api.TranscriptHit>> searchTranscriptHits(
  ProviderReader read,
  String query, {
  int? limit,
}) async {
  try {
    return await read(apiProvider).searchTranscripts(q: query, limit: limit);
  } on api.ApiException catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.ui,
      'Transcript search is not available',
      error,
      stack,
    );
    return const [];
  }
}
