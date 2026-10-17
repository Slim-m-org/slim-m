// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-web stub. `link_preview_card.dart` only reaches this widget under
/// `kIsWeb`, so this is never actually built - it exists purely so
/// `youtube_inline_player.dart`'s conditional import resolves on every
/// platform.
library;

import 'package:flutter/widgets.dart';

Widget buildYoutubeInlinePlayer(Uri embedUrl) => const SizedBox.shrink();
