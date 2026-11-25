// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the local channel row says about boards and calls, mirroring the api model.
library;

import 'database.dart';

extension ChannelKinds on Channel {
  bool get isThread => parentMessageId != null;

  bool get isCanvasChannel => kind == 'canvas';

  /// Whether a board exists here; an older server's silence means the old rule.
  bool get hasCanvas =>
      !isThread &&
      (canvasEnabled ?? (kind == 'voice' || kind == 'dm' || isCanvasChannel));

  /// Whether a channel call runs here; a DM keeps its own call path.
  bool get hostsCall =>
      !isThread && kind != 'dm' && (voiceEnabled ?? kind == 'voice');
}
