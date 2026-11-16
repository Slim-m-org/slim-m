// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The band across the top of a profile card: the person's banner image, or
/// their profile colour when they have none. A gif holds still while the
/// window is unfocused or covered, like every other animation here.
library;

import 'dart:math' as math;

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

/// How a band with no image is drawn; both stay selectable until the owner picks one.
enum ProfileBandLook {
  /// A diagonal from the colour, muted, to a darker shade of it.
  gradient,

  /// The colour washed over the card's own surface, fading down.
  tonal,
}

/// The look every band draws; a test overrides it to render the other one.
final profileBandLookProvider = Provider<ProfileBandLook>(
  (ref) => ProfileBandLook.gradient,
);

/// The no-image band for [colour] in [look], on a card of [surface].
Decoration profileBandDecoration(
  Color colour,
  ProfileBandLook look,
  Color surface,
) => switch (look) {
  ProfileBandLook.gradient => _gradientBand(colour),
  ProfileBandLook.tonal => _tonalBand(
    nudgeForContrast(colour, surface, minRatio: 2),
  ),
};

Decoration _gradientBand(Color colour) {
  final hsl = HSLColor.fromColor(colour);
  final light = hsl.withSaturation(math.min(hsl.saturation, 0.55));
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        light.toColor(),
        light.withLightness(light.lightness * 0.6).toColor(),
      ],
    ),
  );
}

/// Translucent rather than blended with a token, so it takes whatever surface the card is.
Decoration _tonalBand(Color colour) => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [colour.withValues(alpha: 0.45), colour.withValues(alpha: 0.3)],
  ),
);

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
    final look = ref.watch(profileBandLookProvider);
    final fill = switch (colour) {
      final colour? => DecoratedBox(
        decoration: profileBandDecoration(colour, look, tokens.surfaceRaised),
        child: const SizedBox.expand(),
      ),
      null => ColoredBox(color: tokens.surfaceSunken),
    };
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

/// The band for a member's card, in their profile colour (or the preset their
/// disc falls back to) until they set an image.
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
      colour: profileColourOfUser(live) ?? defaultProfileColour(live.id),
    );
  }
}
