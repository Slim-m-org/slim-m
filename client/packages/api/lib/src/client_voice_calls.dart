// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// A voice channel's call history (decision 0066).
extension SlimmApiVoiceCalls on SlimmApi {
  /// The channel's recent calls, newest first; [limit] is 1 to 30.
  Future<VoiceCallHistory> listVoiceCalls(String channelId,
      {int? limit}) async {
    final json = await send(
      'GET',
      '/channels/$channelId/voice/calls',
      query: {if (limit != null) 'limit': '$limit'},
    );
    return VoiceCallHistory.fromJson(json as Map<String, dynamic>);
  }
}
