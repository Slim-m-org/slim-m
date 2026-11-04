// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hover fill of a row that can sit over an image backdrop.
library;

import 'package:flutter/painting.dart';

import 'app_tokens.dart';

extension RowHover on AppTokens {
  /// [surfaceRaised] at partial alpha, so a backdrop shows through instead of
  /// a hard opaque band.
  Color get rowHoverFill => surfaceRaised.withValues(alpha: 0.6);

  /// What [rowHoverFill] looks like over a plain [surfaceBase] row.
  Color get rowHoverFillOnBase => Color.alphaBlend(rowHoverFill, surfaceBase);
}
