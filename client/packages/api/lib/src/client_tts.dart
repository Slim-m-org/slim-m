// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'client.dart';
import 'client_transport.dart';

/// Text to speech into a call (decision 0142). The `voice` tag.
extension SlimmApiTts on SlimmApi {
  /// Queues [text] to be spoken into the call the caller is in on [channelId],
  /// returning how many lines are ahead of it. The route speaks the line; the
  /// caller posts the same text to the chat as an ordinary message.
  Future<int> speakTts(String channelId, String text) async {
    final json = await send(
      'POST',
      '/channels/$channelId/voice/tts',
      body: {'text': text},
    );
    return (json as Map<String, dynamic>)['ahead'] as int;
  }
}
