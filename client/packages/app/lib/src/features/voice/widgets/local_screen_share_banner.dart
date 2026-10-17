// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pending half of a screen share: a system picker the caller has to go
/// answer. A live share has no banner (decision 0047, point 8): the share
/// control and the stage caption carry it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Says a share is requested but not yet live, which a bare spinner on the
/// share button cannot. `info`, never accent: nothing is being shared yet.
class LocalScreenSharePendingBanner extends StatelessWidget {
  const LocalScreenSharePendingBanner({super.key});

  @override
  Widget build(BuildContext context) => const AppCallout(
    tone: AppCalloutTone.info,
    icon: AppIcons.screenShare,
    child: Text(
      'Waiting for you to start the broadcast. Tap the share button to '
      'cancel.',
    ),
  );
}
