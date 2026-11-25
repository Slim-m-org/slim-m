// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' Canvas row for a voice channel: the shared board on or off, saved through `PATCH /channels/{id}`.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import 'channel_settings_flag_toggle.dart';

class ChannelCanvasSection extends StatelessWidget {
  const ChannelCanvasSection({super.key, required this.channel});

  final Channel channel;

  @override
  Widget build(BuildContext context) => ChannelFlagToggle(
    channel: channel,
    label: 'Canvas',
    description: 'A shared board for this call; turning it off only hides it.',
    semanticLabel: 'Add a canvas to this channel',
    whatFailed: 'change the canvas',
    // A server that omits the flag always had a board on a voice channel.
    read: (c) => c.hasCanvas,
    update: (on) => ChannelUpdate(canvasEnabled: on),
  );
}
