// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-web stub. A link preview only reaches this widget under `kIsWeb`,
/// so this is never actually built - it exists purely so
/// `inline_embed_frame.dart`'s conditional import resolves on every platform.
library;

import 'package:flutter/widgets.dart';

Widget buildInlineEmbedFrame(Uri src, {required String allow}) =>
    const SizedBox.shrink();
