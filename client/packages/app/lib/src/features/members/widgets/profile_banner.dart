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
import '../../../widgets/image_decode.dart';
import '../providers/banner_bytes.dart';
import '../providers/member_presence.dart' show memberProfileOverridesProvider;
import 'profile_colour.dart';

/// Height of the band on the 300 wide desktop popover, the card the shape is drawn from.
const double kProfileBannerHeight = 56;

/// Width over height of the band on every surface, and of the crop a person frames for it.
const double kProfileBannerAspect = 300 / kProfileBannerHeight;

/// The widest a banner is decoded for, in logical pixels: a card is never wider.
const double _decodeWidth = 520;

class ProfileBanner extends ConsumerWidget {
  const ProfileBanner({
    super.key,
    required this.userId,
    required this.bannerUpdatedAt,
    required this.colour,
    this.height,
  });

  final String userId;

  /// Null draws the colour alone, and asks for nothing.
  final int? bannerUpdatedAt;

  /// Drawn when there is no image, and under it while it loads.
  final Color? colour;

  /// A fixed height for a thumbnail; null keeps the shared banner shape at any width.
  final double? height;

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
    final band = ExcludeSemantics(
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
    );
    final fixed = height;
    if (fixed != null) {
      return SizedBox(height: fixed, width: double.infinity, child: band);
    }
    return AspectRatio(aspectRatio: kProfileBannerAspect, child: band);
  }
}

/// The band for a member's card, in their profile colour until they set an image.
///
/// Reads the live profile edits first: the roster snapshot a card is opened
/// from never refetches on a banner or colour change.
class MemberProfileBanner extends ConsumerWidget {
  const MemberProfileBanner({super.key, required this.profile});

  final api.UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live =
        ref.watch(
          memberProfileOverridesProvider.select((m) => m[profile.id]),
        ) ??
        profile;
    return ProfileBanner(
      userId: live.id,
      bannerUpdatedAt: live.bannerUpdatedAt,
      colour: profileColourOf(
        index: live.profileColor,
        rgb: live.profileColorRgb,
      ),
    );
  }
}
