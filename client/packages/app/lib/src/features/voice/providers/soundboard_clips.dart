// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's soundboard clips and their cached audio.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

/// The clips, refetched whenever nothing is watching them.
final soundClipsProvider = FutureProvider.autoDispose<List<SoundClip>>(
  (ref) => ref.watch(apiProvider).listSoundClips(),
);

/// One clip's audio, kept for the session: the bytes never change under an id,
/// so a clip is fetched once and every later play is local.
final soundClipAudioProvider = FutureProvider.family<FetchedBytes, String>(
  (ref, clipId) => ref.watch(apiProvider).fetchSoundClipAudio(clipId),
);
