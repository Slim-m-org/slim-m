// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The corner control that pops a feed out into its own OS window.
///
/// Absent, never disabled, wherever [popOutSupportedProvider] is false, so the
/// web build and any desktop build without the windowing flag never show it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_mini_player.dart';
import '../providers/popout_window.dart';

class PopOutVideoButton extends ConsumerWidget {
  const PopOutVideoButton({super.key, required this.feed});

  final MiniPlayerFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(popOutSupportedProvider)) return const SizedBox.shrink();
    final label = switch (feed.kind) {
      FeedKind.screenShare => "Pop out ${feed.name}'s screen",
      FeedKind.camera => "Pop out ${feed.name}'s camera",
    };
    void open() => ref.read(popOutFeedProvider.notifier).state = feed;
    return Semantics(
      button: true,
      label: label,
      onTap: open,
      child: GestureDetector(
        excludeFromSemantics: true,
        onTap: open,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          child: const Icon(AppIcons.popOut, size: 14, color: Colors.white),
        ),
      ),
    );
  }
}
