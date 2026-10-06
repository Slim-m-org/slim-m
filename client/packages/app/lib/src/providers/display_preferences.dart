// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Three accessibility and display preferences the owner asked for by name:
/// a 12/24-hour clock, an in-app override of reduce-motion, and a high-
/// contrast toggle. All three follow [ThemeController]'s own shape in
/// `providers.dart` - a `StateNotifier` restored from [preferencesProvider]
/// before the first frame and persisted on every change - kept in their own
/// file rather than added to that one, which is already past its review
/// budget.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'preference_controller.dart';

/// Whether the clock reads 12-hour or 24-hour. [system] is the default,
/// following the device's own reported setting via
/// [MediaQuery.alwaysUse24HourFormat] - the same signal iOS and Android
/// already surface for exactly this, so a fresh install matches whatever the
/// device's own clock already reads without asking anyone anything.
enum TimeFormatPreference { system, h12, h24 }

const timeFormatPreferenceKey = 'slimm.appearance.time_format';

/// [pref] resolved against [context]'s own device setting.
bool resolveUse24Hour(BuildContext context, TimeFormatPreference pref) =>
    switch (pref) {
      TimeFormatPreference.h24 => true,
      TimeFormatPreference.h12 => false,
      TimeFormatPreference.system => MediaQuery.alwaysUse24HourFormatOf(
        context,
      ),
    };

class TimeFormatController
    extends EnumPreferenceController<TimeFormatPreference> {
  TimeFormatController(super.ref)
    : super(
        storageKey: timeFormatPreferenceKey,
        choices: TimeFormatPreference.values,
        fallback: TimeFormatPreference.system,
      );
}

final timeFormatControllerProvider =
    StateNotifierProvider<TimeFormatController, TimeFormatPreference>(
      TimeFormatController.new,
    );

/// The resolved 12/24-hour answer for the current build context, in one call
/// so a leaf widget need not import both this provider and [resolveUse24Hour].
bool watchUse24Hour(WidgetRef ref, BuildContext context) =>
    resolveUse24Hour(context, ref.watch(timeFormatControllerProvider));

const motionPreferenceKey = 'slimm.appearance.motion';

class MotionPreferenceController
    extends EnumPreferenceController<MotionOverride> {
  MotionPreferenceController(super.ref)
    : super(
        storageKey: motionPreferenceKey,
        choices: MotionOverride.values,
        fallback: MotionOverride.system,
      );
}

final motionPreferenceControllerProvider =
    StateNotifierProvider<MotionPreferenceController, MotionOverride>(
      MotionPreferenceController.new,
    );

const highContrastPreferenceKey = 'slimm.appearance.high_contrast';

/// Off by default: the boosted border and disabled-text roles are a
/// deliberate change to how quiet the app reads, not a correction, so
/// nothing changes for an install that has never opened the control.
class HighContrastController extends BoolPreferenceController {
  HighContrastController(super.ref)
    : super(storageKey: highContrastPreferenceKey);
}

final highContrastControllerProvider =
    StateNotifierProvider<HighContrastController, bool>(
      HighContrastController.new,
    );
