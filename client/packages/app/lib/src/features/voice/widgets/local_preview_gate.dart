// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wraps the member's own preview so a paused one says so instead of going black.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/video_pause.dart';
import 'video_state_card.dart';

class LocalPreviewGate extends ConsumerWidget {
  const LocalPreviewGate({
    super.key,
    required this.identity,
    required this.name,
    required this.screenShare,
    required this.child,
  });

  final String identity;
  final String name;
  final bool screenShare;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localPreviewPausedProvider)) return child;
    return VideoStateCard(
      icon: screenShare ? AppIcons.screenShare : AppIcons.camera,
      title: "Preview paused while you're in another window",
      identity: identity,
      name: name,
      actionLabel: 'Resume',
      onAction: () =>
          ref.read(localPreviewResumedProvider.notifier).state = true,
    );
  }
}
