// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sorts a call's roster into what the stage fit lays out.
///
/// Order is by kind and never by who is talking, so nothing moves on speech:
/// shares, then cameras, then audio-only people.
library;

import 'package:slimm_rtc/rtc.dart';

import 'stage_item.dart';

/// The fallback aspect until a track reports its own size.
const double stageDefaultAspect = 16 / 9;

const String directStageId = 'direct';

String shareItemId(String identity) => 'share:$identity';
String cameraItemId(String identity) => 'cam:$identity';

class StageContent {
  const StageContent({
    required this.items,
    required this.people,
    required this.pinnedIdentity,
  });

  /// The pinned item first, then the other shares, then cameras.
  final List<StageItem> items;

  /// People with neither a camera on nor a share on stage.
  final List<VoiceParticipant> people;

  /// Whose share is pinned, or null when a camera or the direct player is.
  final String? pinnedIdentity;
}

/// [shares] are the watched ones; [pinned] is the one to give the most room.
StageContent buildStageContent({
  required List<VoiceParticipant> participants,
  required List<VoiceParticipant> shares,
  required String? pinned,
  required bool directPlaying,
  double Function(String id)? aspectOf,
}) {
  double aspect(String id) => aspectOf?.call(id) ?? stageDefaultAspect;
  final sharing = {for (final s in shares) s.identity};
  final pinnedShare = shares.any((s) => s.identity == pinned) ? pinned : null;
  final ordered = [
    ...shares.where((s) => s.identity == pinnedShare),
    ...shares.where((s) => s.identity != pinnedShare),
  ];
  final items = <StageItem>[
    if (directPlaying)
      const StageItem(directStageId, StageKind.share, stageDefaultAspect),
    for (final s in ordered)
      StageItem(
        shareItemId(s.identity),
        StageKind.share,
        aspect(shareItemId(s.identity)),
      ),
    for (final p in participants)
      if (p.isCameraOn)
        StageItem(
          cameraItemId(p.identity),
          StageKind.camera,
          aspect(cameraItemId(p.identity)),
        ),
  ];
  return StageContent(
    items: items,
    people: [
      for (final p in participants)
        if (!p.isCameraOn && !sharing.contains(p.identity)) p,
    ],
    pinnedIdentity: directPlaying ? null : pinnedShare,
  );
}
