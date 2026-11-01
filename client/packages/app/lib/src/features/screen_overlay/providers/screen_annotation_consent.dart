// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a sharer lets viewers draw on their screen, as a viewer learns it.
///
/// The sharer repeats a consent frame while the overlay is up; a viewer
/// believes it for [consentLifetime] after the last one. A sharer who turns it
/// off says so once, and one who vanishes simply stops being believed, so a
/// missed frame can only ever remove the pen, never grant it.
library;

import 'package:slimm_api/api.dart' as api;

/// How often a sharer repeats consent.
const consentHeartbeat = Duration(seconds: 5);

/// How long a viewer believes the last consent frame.
const consentLifetime = Duration(seconds: 15);

class SharerConsent {
  const SharerConsent({required this.aspect, required this.seenAt});

  /// The shared screen's width over its height.
  final double? aspect;
  final DateTime seenAt;
}

class ScreenAnnotationConsent {
  final Map<String, SharerConsent> _bySharer = {};

  /// Folds in a relayed frame; only consent frames from the sharer themselves count.
  void apply(api.CanvasScreenAnnotation frame, DateTime now) {
    if (frame.kind != 'consent' || frame.userId != frame.targetUserId) return;
    if (!frame.allowed) {
      _bySharer.remove(frame.userId);
      return;
    }
    _bySharer[frame.userId] = SharerConsent(aspect: frame.aspect, seenAt: now);
  }

  /// The sharer's live consent at [now], or null when they have not allowed drawing.
  SharerConsent? of(String sharerId, DateTime now) {
    final consent = _bySharer[sharerId];
    if (consent == null) return null;
    if (now.difference(consent.seenAt) > consentLifetime) {
      _bySharer.remove(sharerId);
      return null;
    }
    return consent;
  }

  bool get isEmpty => _bySharer.isEmpty;
}
