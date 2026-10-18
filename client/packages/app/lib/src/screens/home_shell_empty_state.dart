// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the conversation pane shows with no channel chosen.
library;

import 'package:flutter/material.dart';

import '../features/home/widgets/home_pane.dart';

/// The home: welcome on a first visit, what is new after an update, and
/// otherwise a quiet look at what is waiting.
class NoChannelSelected extends StatelessWidget {
  const NoChannelSelected({super.key});

  @override
  Widget build(BuildContext context) => const HomePane();
}
