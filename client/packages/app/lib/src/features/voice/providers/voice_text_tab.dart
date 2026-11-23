// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which of a voice channel's two texts its chat pane shows while a
/// transcript runs: the channel's chat, or what is being said in the call.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VoiceTextTab { chat, transcript }

/// Kept apart from `voiceChatPaneVisibleProvider`, which stays a plain open-or-shut bool.
final voiceTextTabProvider = StateProvider<VoiceTextTab>(
  (ref) => VoiceTextTab.chat,
);
