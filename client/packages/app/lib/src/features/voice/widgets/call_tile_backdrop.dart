// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What fills a call tile behind the avatar: the member's profile colour.
/// A profile banner image slots in here later; nothing else on the tile
/// knows where its background comes from.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';
import '../../members/widgets/profile_colour.dart';

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);

/// Fills its box with [identity]'s profile colour (the raised surface until
/// the profile resolves) and hands [builder] a legible text colour for it.
class CallTileBackdrop extends ConsumerWidget {
  const CallTileBackdrop({
    super.key,
    required this.identity,
    required this.builder,
  });

  final String identity;
  final Widget Function(BuildContext context, Color onBackdrop) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final profile = ref.watch(userProfileProvider(identity)).valueOrNull;
    final colour = profile == null
        ? null
        : profileColourOf(
            index: profile.profileColor,
            rgb: profile.profileColorRgb,
          );
    if (colour == null) {
      return ColoredBox(
        color: tokens.surfaceRaised,
        child: builder(context, tokens.textPrimary),
      );
    }
    final onColour = contrastRatio(colour, _white) >= 4.5 ? _white : _black;
    return ColoredBox(color: colour, child: builder(context, onColour));
  }
}
