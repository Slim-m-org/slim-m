// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space switch for turning voice messages into text on the server.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart';

import '../../widgets/space_setting_switch_section.dart';

class VoiceMessageTranscriptsSection extends StatelessWidget {
  const VoiceMessageTranscriptsSection({super.key});

  @override
  Widget build(BuildContext context) => SpaceSettingSwitchSection(
    title: 'Voice messages',
    label: 'Transcribe voice messages',
    description: 'Members read them without playing them.',
    semanticLabel: 'Transcribe voice messages',
    whatFailed: 'change voice message transcripts',
    read: (settings) => settings.transcribeVoiceMessages,
    update: (on) => SpaceSettingsUpdate(transcribeVoiceMessages: on),
    isAvailable: (settings) => settings.transcribeVoiceMessagesAvailable,
    unavailableReason:
        'Needs the call listener, which this server is not running.',
  );
}
