// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Call transcripts kept by the server (decision 0113).
extension SlimmApiCallTranscripts on SlimmApi {
  /// A page of the transcript's lines after [afterSeq]; 404 when the reader
  /// may not see it.
  Future<CallTranscript> callTranscript(
    String id, {
    int? afterSeq,
    int? limit,
  }) async {
    final json = await send(
      'GET',
      '/voice/transcripts/$id',
      query: {
        if (afterSeq != null) 'after_seq': '$afterSeq',
        if (limit != null) 'limit': '$limit',
      },
    );
    return CallTranscript.fromJson(json as Map<String, dynamic>);
  }

  /// Deletes the transcript and its lines. Needs MANAGE_MESSAGES.
  Future<void> deleteCallTranscript(String id) =>
      send('DELETE', '/voice/transcripts/$id', expectNoContent: true);

  /// Lines matching [q] across every channel the reader may read, newest first.
  Future<List<TranscriptHit>> searchTranscripts({
    required String q,
    int? before,
    int? limit,
  }) async {
    final json = await send(
      'GET',
      '/search/transcripts',
      query: {
        'q': q,
        if (before != null) 'before': '$before',
        if (limit != null) 'limit': '$limit',
      },
    );
    return [
      for (final raw in json as List<dynamic>)
        TranscriptHit.fromJson(raw as Map<String, dynamic>),
    ];
  }

  /// The Space's mode and whether the caller has seen the `always` notice.
  Future<TranscriptionNotice> transcriptionNotice() async {
    final json = await send('GET', '/voice/transcription-notice');
    // A reply that is not an object reads as nothing owed, like a missing route.
    return json is Map<String, dynamic>
        ? TranscriptionNotice.fromJson(json)
        : const TranscriptionNotice(
            mode: CallTranscriptionMode.off,
            acknowledged: true,
          );
  }

  /// Records that the caller saw the notice, on every device. Idempotent.
  Future<void> ackTranscriptionNotice() =>
      send('POST', '/voice/transcription-notice/ack', expectNoContent: true);
}
