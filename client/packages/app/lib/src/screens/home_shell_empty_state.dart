// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the conversation pane shows with no channel chosen.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart' show kCompactWidth;

import '../features/home/widgets/home_pane.dart';

/// The home: welcome on a first visit, what is new after an update, and
/// otherwise a quiet look at what is waiting.
class NoChannelSelected extends StatelessWidget {
  const NoChannelSelected({super.key});

  @override
  Widget build(BuildContext context) => const HomePane();
}

/// The routed page for no channel chosen. Below `kCompactWidth` the channel
/// list is the whole screen then, so this is empty: it is only ever seen
/// under a channel sliding in, and a home pane nobody saw must not count as read.
class NoChannelPage extends StatelessWidget {
  const NoChannelPage({super.key});

  @override
  Widget build(BuildContext context) =>
      MediaQuery.sizeOf(context).width < kCompactWidth
      ? const SizedBox.shrink()
      : const NoChannelSelected();
}
