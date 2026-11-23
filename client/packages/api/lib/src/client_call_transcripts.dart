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

  /// Every mark and note on the transcript, oldest first; 404 when the reader
  /// may not see it.
  Future<List<TranscriptMark>> callTranscriptMarks(String id) async {
    final json = await send('GET', '/voice/transcripts/$id/marks');
    // A reply with no list reads as no marks, like a server that predates them.
    final marks = json is Map<String, dynamic> ? json['marks'] : null;
    if (marks is! List<dynamic>) return const [];
    return [
      for (final raw in marks)
        TranscriptMark.fromJson(raw as Map<String, dynamic>),
    ];
  }

  /// Marks the current moment of a running transcribed call, with [note] when
  /// given. [markId] is a UUIDv7 the caller mints, so a retry is the same mark.
  Future<TranscriptMark> putCallTranscriptMark(
    String transcriptId,
    String markId, {
    String? note,
  }) async {
    final json = await send(
      'PUT',
      '/voice/transcripts/$transcriptId/marks/$markId',
      body: {
        'kind': note == null ? 'mark' : 'note',
        if (note != null) 'text': note,
      },
    );
    return TranscriptMark.fromJson(json as Map<String, dynamic>);
  }

  /// Removes a mark. The author, or someone with MANAGE_MESSAGES.
  Future<void> deleteCallTranscriptMark(String transcriptId, String markId) =>
      send(
        'DELETE',
        '/voice/transcripts/$transcriptId/marks/$markId',
        expectNoContent: true,
      );

  /// Deletes the transcript and its lines. Needs MANAGE_MESSAGES.
  Future<void> deleteCallTranscript(String id) =>
      send('DELETE', '/voice/transcripts/$id', expectNoContent: true);

  /// Lines matching [q] across every channel the reader may read, newest first.
  /// Pass the last hit as [after] for the next page.
  Future<List<TranscriptHit>> searchTranscripts({
    required String q,
    int? before,
    TranscriptHit? after,
    int? limit,
  }) async {
    final json = await send(
      'GET',
      '/search/transcripts',
      query: {
        'q': q,
        if (after != null) ...{
          'before': '${after.at}',
          'before_transcript_id': after.transcriptId,
          'before_seq': '${after.seq}',
        } else if (before != null)
          'before': '$before',
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

  /// The caller's own talk statistics, never anyone else's. [days] limits the
  /// window, [timezone] sets the day buckets and [transcriptId] counts one call.
  Future<CallStats> myCallStats({
    int? days,
    String? timezone,
    String? transcriptId,
  }) async {
    final json = await send(
      'GET',
      '/me/call-stats',
      query: {
        if (days != null) 'days': '$days',
        if (timezone != null) 'tz': timezone,
        if (transcriptId != null) 'transcript_id': transcriptId,
      },
    );
    return CallStats.fromJson(json as Map<String, dynamic>);
  }
}
