// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transcript a call is writing right now, for someone who may read it
/// (decision 0113): what captions and the live pane follow.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../permissions.dart';
import '../../channels/providers/channel_permissions.dart';
import 'call_audio.dart';

/// The running transcript in [channelId]'s call while the server writes one
/// and this member holds VIEW_CHANNEL and VIEW_TRANSCRIPTS there; null otherwise.
final liveCallTranscriptIdProvider = Provider.autoDispose
    .family<String?, String>((ref, channelId) {
      final session = ref.watch(
        callAudioProvider(channelId).select((m) => m.session),
      );
      final id = session?.transcriptId;
      if (id == null || !session!.isServerTranscript || !session.isOn) {
        return null;
      }
      final bits = ref.watch(myChannelPermissionsProvider(channelId));
      return bits.hasPermission(Perm.viewChannel | Perm.viewTranscripts)
          ? id
          : null;
    });
