// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The presence mark for a member who is online from a phone and nothing
/// else, drawn where the online dot would be.
library;

import 'package:flutter/material.dart';

import '../../app_icons.dart';
import '../../app_tokens.dart';

/// A phone glyph in the online colour. Colour is not the only cue: the
/// silhouette alone says "phone", and the label says "online on phone".
class AppPresencePhoneMark extends StatelessWidget {
  const AppPresencePhoneMark({super.key, required this.size});

  /// The glyph's box, as the avatar geometry sizes the presence mark.
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      label: 'online on phone',
      child: Icon(
        AppIcons.presencePhone,
        size: size,
        color: tokens.status.online,
      ),
    );
  }
}
