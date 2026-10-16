// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full-width rule a flush settings card draws between its children, for a
/// child that holds more than one row of its own.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsHairline extends StatelessWidget {
  const SettingsHairline({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    color: Theme.of(context).extension<AppTokens>()!.borderSubtle,
  );
}
