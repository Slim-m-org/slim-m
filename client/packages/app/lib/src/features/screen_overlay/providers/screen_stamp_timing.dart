// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a stamp on a shared screen lives (decision 0121): it pops in once its
/// picture is ready, holds, then fades like every other mark.
library;

import 'package:flutter/animation.dart' show Curves;
import 'package:slimm_design_system/design_system.dart' show AppMotion;

/// How long a stamp stays at full strength once it is painted.
const annotationStampHold = Duration(seconds: 8);

/// A stamp whose picture has not arrived this long after the stamp did is dropped rather than shown late.
const annotationStampReadyWithin = Duration(seconds: 5);

/// The pop-in, `duration.base`.
const annotationStampPop = AppMotion.base;

/// The scale a stamp pops in from.
const stampPopFrom = 0.6;

/// Live stamps one person may have on one screen; a fourth starts the oldest fading.
const maxStampsPerAuthor = 3;

/// Live stamps one screen holds from everyone together.
const maxStampsPerScreen = 12;

/// A stamp's longest side as a fraction of the shared screen's height: the tap default and the drag bounds, as the server clamps it.
const stampDefaultSize = 0.12;
const stampMinSize = 0.04;
const stampMaxSize = 0.30;

/// The pop-in scale [sinceReady] after a stamp was ready: 60% to full with a slight overshoot, or full at once with reduced motion.
double stampPopScale(Duration sinceReady, {bool reduceMotion = false}) {
  if (reduceMotion || sinceReady >= annotationStampPop) return 1;
  if (sinceReady <= Duration.zero) return stampPopFrom;
  final t = sinceReady.inMicroseconds / annotationStampPop.inMicroseconds;
  return stampPopFrom + (1 - stampPopFrom) * Curves.easeOutBack.transform(t);
}

/// [size] held to the bounds the server keeps it in.
double clampStampSize(double size) =>
    size.isFinite ? size.clamp(stampMinSize, stampMaxSize) : stampDefaultSize;
