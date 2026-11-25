// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' Voice call row for a canvas channel: whether people can talk while they work, saved through `PATCH /channels/{id}`.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import 'channel_settings_flag_toggle.dart';

class ChannelCallSection extends StatelessWidget {
  const ChannelCallSection({super.key, required this.channel});

  final Channel channel;

  @override
  Widget build(BuildContext context) => ChannelFlagToggle(
    channel: channel,
    label: 'Voice call',
    description: 'Lets people talk while they work.',
    semanticLabel: 'Let people call in this channel',
    whatFailed: 'change the voice call',
    read: (c) => c.hostsCall,
    update: (on) => ChannelUpdate(voiceEnabled: on),
  );
}
