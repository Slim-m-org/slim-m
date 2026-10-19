// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The band across the top of a profile card: the person's banner image, or
/// their profile colour when they have none. A gif holds still while the
/// window is unfocused or covered, like every other animation here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/animation_gate.dart';
import '../../messages/widgets/image_decode.dart';
import '../providers/banner_bytes.dart';
import 'profile_colour.dart';

/// Height of the band; the card's width is whatever it sits in.
const double kProfileBannerHeight = 56;

/// The widest a banner is decoded for, in logical pixels: a card is never wider.
const double _decodeWidth = 520;

class ProfileBanner extends ConsumerWidget {
  const ProfileBanner({
    super.key,
    required this.userId,
    required this.bannerUpdatedAt,
    required this.colour,
  });

  final String userId;

  /// Null draws the colour alone, and asks for nothing.
  final int? bannerUpdatedAt;

  /// Drawn when there is no image, and under it while it loads.
  final Color? colour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final fill = ColoredBox(color: colour ?? tokens.surfaceSunken);
    final updatedAt = bannerUpdatedAt;
    final bytes = updatedAt == null
        ? null
        : ref
              .watch(
                bannerBytesProvider((userId: userId, updatedAt: updatedAt)),
              )
              .valueOrNull;
    return SizedBox(
      height: kProfileBannerHeight,
      width: double.infinity,
      child: ExcludeSemantics(
        child: bytes == null
            ? fill
            : AnimationGate(
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: decodeEdge(context, _decodeWidth),
                  errorBuilder: (context, error, stack) => fill,
                ),
              ),
      ),
    );
  }
}

/// The band for a member's card, in their profile colour until they set an image.
class MemberProfileBanner extends StatelessWidget {
  const MemberProfileBanner({super.key, required this.profile});

  final api.UserProfile profile;

  @override
  Widget build(BuildContext context) => ProfileBanner(
    userId: profile.id,
    bannerUpdatedAt: profile.bannerUpdatedAt,
    colour: profileColourOf(
      index: profile.profileColor,
      rgb: profile.profileColorRgb,
    ),
  );
}
