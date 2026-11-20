// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stamp in hand (decision 0121), one for every surface: the share tile's
/// pill and the board's Stamp tool place the same thing. Kept for the session.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import '../../../providers/server_info.dart';
import '../../screen_overlay/providers/stamp_content.dart';

/// Pictures the Picture tab offers again.
const recentStampPicturesKept = 8;

class ArmedStamp {
  const ArmedStamp({this.content, this.recentPictures = const []});

  /// What a tap places; null until something is picked.
  final StampContent? content;

  /// The pictures picked this session, newest first.
  final List<PictureStamp> recentPictures;
}

class ArmedStampController extends Notifier<ArmedStamp> {
  /// Dropped when the account signs out, signs in as someone else or changes server.
  @override
  ArmedStamp build() {
    ref
      ..watch(sessionProvider)
      ..watch(serverUrlProvider);
    return const ArmedStamp();
  }

  void arm(StampContent content) => state = ArmedStamp(
    content: content,
    recentPictures: content is PictureStamp
        ? [
            content,
            ...state.recentPictures.where(
              (p) => p.attachmentId != content.attachmentId,
            ),
          ].take(recentStampPicturesKept).toList(growable: false)
        : state.recentPictures,
  );
}

final armedStampProvider = NotifierProvider<ArmedStampController, ArmedStamp>(
  ArmedStampController.new,
);

/// Whether the board takes emoji stamps, which arrive with the screen stamp capability (decision 0121).
final canvasStampsSupportedProvider = Provider<bool>(
  (ref) => ref.watch(
    serverInfoProvider.select(
      (info) => info.valueOrNull?.supportsScreenStamps ?? false,
    ),
  ),
);
