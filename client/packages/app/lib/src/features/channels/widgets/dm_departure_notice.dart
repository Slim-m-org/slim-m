// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line above a DM's composer when the other people have left the Space.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/dm_departure.dart';

class DmDepartureNotice extends StatelessWidget {
  const DmDepartureNotice({super.key, required this.departure});

  final DmDeparture departure;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.s16,
      AppSpacing.s8,
      AppSpacing.s16,
      AppSpacing.s8,
    ),
    child: AppCallout(tone: AppCalloutTone.info, child: Text(departure.notice)),
  );
}
