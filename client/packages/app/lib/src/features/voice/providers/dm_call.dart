// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The DM channel whose call pane is open, or null.
///
/// Split out of `screens/dm_call_pane.dart` (which still exports it, so
/// nothing importing it from there needs to change) so
/// `screens/voice_join_preview.dart`'s recap screen can read it too, without
/// a cyclic import between the two screen files: `dm_call_pane.dart` already
/// imports `voice_screen.dart` to embed the call itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../channels/providers/channel_by_id_provider.dart';

final dmCallOpenProvider = StateProvider<String?>((ref) => null);

/// Whether [channelId] is a DM, judged from what the app already holds so a read never starts a fetch.
bool isDirectCall(Ref ref, String channelId) =>
    ref.read(dmCallOpenProvider) == channelId ||
    (ref.exists(channelIsDmProvider(channelId)) &&
        ref.read(channelIsDmProvider(channelId)));
