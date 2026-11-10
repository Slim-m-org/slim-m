// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The round picture each call-panel row carries: the cached avatar baked once per person and picture, initials until it arrives (decision 0096).
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart' show initialsFor;

import '../../members/providers/avatar_bytes.dart';
import 'call_overlay_avatar_render.dart';

/// A baked picture and the key that names which one it is.
class OverlayAvatar {
  const OverlayAvatar({required this.key, required this.png});

  final String key;
  final Uint8List png;
}

/// Who a picture is for: the user id, and the name its initials come from.
typedef OverlayAvatarWho = ({String id, String name});

typedef OverlayAvatarRenderer =
    Future<Uint8List> Function({
      required String name,
      required String tintKey,
      Uint8List? picture,
    });

/// The baker behind a seam; a test supplies bytes without an engine.
final overlayAvatarRendererProvider = Provider<OverlayAvatarRenderer>(
  (ref) => renderOverlayAvatar,
);

/// Initials first, then the picture when its bytes land, and again when the person changes it.
final callOverlayAvatarProvider = FutureProvider.autoDispose
    .family<OverlayAvatar, OverlayAvatarWho>((ref, who) async {
      final (:version, bytes: picture) = ref.watch(
        currentAvatarProvider(who.id),
      );
      final png = await ref.watch(overlayAvatarRendererProvider)(
        name: who.name,
        tintKey: who.id,
        picture: picture,
      );
      return OverlayAvatar(
        key: '$version/${picture != null}/${initialsFor(who.name)}',
        png: png,
      );
    });
