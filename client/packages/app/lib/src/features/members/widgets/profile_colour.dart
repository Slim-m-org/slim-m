// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a profile colour comes from: a custom one when the person picked
/// it, otherwise one of the six presets, the same everywhere it is drawn.
library;

import 'package:flutter/painting.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// [rgb] (0xRRGGBB) when set, else the preset at [index]; null when neither is known.
Color? profileColourOf({int? index, int? rgb}) {
  if (rgb != null) return Color(0xFF000000 | rgb);
  if (index == null) return null;
  const presets = AppCanvasColors.cursors;
  return presets[index % presets.length];
}

/// [profile]'s colour, as [profileColourOf] reads it.
Color? profileColourOfUser(api.UserProfile profile) =>
    profileColourOf(index: profile.profileColor, rgb: profile.profileColorRgb);

/// The preset the server gives [userId] until its owner picks one (`default_profile_color`:
/// the id's last byte), for when the profile is not to hand; a non-UUID id is hashed.
Color defaultProfileColour(String userId) {
  const presets = AppCanvasColors.cursors;
  final tail = userId.length < 2 ? null : userId.substring(userId.length - 2);
  final byte = tail == null ? null : int.tryParse(tail, radix: 16);
  return presets[byte == null
      ? stableIndexFor(userId, presets.length)
      : byte % presets.length];
}

/// The member card's avatar ring, moved just far enough from [surface] to
/// stay visible when a custom colour sits too close to it.
Color? profileRingColour(api.UserProfile profile, Color surface) {
  final colour = profileColourOfUser(profile);
  return colour == null ? null : nudgeForContrast(colour, surface);
}

/// 0xRRGGBB for [colour], what the server stores.
int rgbOf(Color colour) => rgbOfColour(colour);
