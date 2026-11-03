// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts the personal background picture behind the shell's panes.
///
/// The tree is the same with or without a picture, so turning it on or off
/// from settings never remounts the conversation under it.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/providers/display_preferences.dart';
import '../providers/app_background_controller.dart';

/// Whether a picture shows behind the panes: there is one, and neither this
/// app's high contrast nor the platform's is asking for plain surfaces.
bool backgroundWanted(WidgetRef ref, BuildContext context) {
  final settings = ref.watch(appBackgroundControllerProvider);
  final highContrast =
      ref.watch(highContrastControllerProvider) ||
      MediaQuery.highContrastOf(context);
  return settings.hasImage && !highContrast;
}

class AppBackgroundHost extends ConsumerWidget {
  const AppBackgroundHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final picture = backgroundWanted(ref, context)
        ? ref.watch(backgroundPictureProvider).valueOrNull
        : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: tokens.surfaceBase,
            child: picture == null ? null : _layer(ref, tokens, picture),
          ),
        ),
        AppBackgroundScope(
          paneAlpha: picture == null ? null : kBackgroundPaneAlpha,
          child: child,
        ),
      ],
    );
  }

  Widget _layer(WidgetRef ref, AppTokens tokens, ui.Image picture) {
    final settings = ref.watch(appBackgroundControllerProvider);
    return AppBackgroundLayer(
      image: picture,
      base: tokens.surfaceBase,
      style: settings.styleFor(tokens),
    );
  }
}
