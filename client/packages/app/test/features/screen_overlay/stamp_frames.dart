// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A relayed stamp frame, as the server sends one (decision 0121).
library;

import 'package:slimm_api/api.dart' as api;

api.CanvasScreenAnnotation stampFrame({
  String id = 's1',
  String user = 'viewer',
  String target = 'sharer',
  String channel = 'c',
  List<double> points = const [0.4, 0.3],
  double? size = 0.12,
  String? emoji = '\u{1F389}',
  String? attachment,
  bool animated = false,
}) => api.CanvasScreenAnnotation(
  channelId: channel,
  userId: user,
  targetUserId: target,
  kind: 'stamp',
  annotationId: id,
  points: points,
  size: size,
  emoji: attachment == null ? emoji : null,
  attachment: attachment,
  animated: animated,
  ended: true,
  allowed: false,
);
