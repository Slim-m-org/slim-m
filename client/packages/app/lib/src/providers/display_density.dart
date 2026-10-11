// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three per-device display preferences: message density, the extra gap
/// above a new message group, and the whole-interface scale.
///
/// Decision 0062. Each follows the theme's shape: restored before the first
/// frame, persisted on every change.
library;

import 'package:flutter/material.dart' show VisualDensity;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'preference_controller.dart';

const messageDensityKey = 'slimm.appearance.message_density';
const groupSpacingKey = 'slimm.appearance.group_spacing';
const uiScaleKey = 'slimm.appearance.ui_scale';

/// Extra dp above a new group: 0 to 16 in steps of 4, so every value is a
/// spacing token.
const groupSpacingSteps = [0, 4, 8, 12, 16];

/// Interface scale in percent: 80 to 130 in steps of 5.
const uiScaleMin = 80;
const uiScaleMax = 130;
const uiScaleStep = 5;

extension MessageDensityGeometry on AppDensity {
  /// The author avatar step; the continuation gutter is the same width.
  double get avatarSize =>
      this == AppDensity.compact ? AppAvatarSize.s28 : AppAvatarSize.s40;

  /// The avatar in a sheet or list row (pins, saved, threads); one step down
  /// from [avatarSize] because it sits in a two-line tile.
  double get listAvatarSize =>
      this == AppDensity.compact ? AppAvatarSize.s24 : AppAvatarSize.s28;

  /// The gap between search hits and around the thread parent card.
  double get listRowGap => switch (this) {
    AppDensity.compact => AppSpacing.s8,
    AppDensity.normal => AppSpacing.s12,
    AppDensity.spacious => AppSpacing.s16,
  };

  /// Vertical padding inside a search hit.
  double get hitInset => switch (this) {
    AppDensity.compact => 0,
    AppDensity.normal => AppSpacing.s4,
    AppDensity.spacious => AppSpacing.s8,
  };

  /// Taller or shorter sheet tiles; Default keeps Material's own height.
  VisualDensity get tileVisualDensity => this == AppDensity.spacious
      ? const VisualDensity(vertical: 1)
      : VisualDensity.standard;
}

class MessageDensityController extends EnumPreferenceController<AppDensity> {
  MessageDensityController(super.ref)
    : super(
        storageKey: messageDensityKey,
        choices: AppDensity.values,
        fallback: AppDensity.normal,
      );
}

final messageDensityControllerProvider =
    StateNotifierProvider<MessageDensityController, AppDensity>(
      MessageDensityController.new,
    );

class GroupSpacingController extends IntPreferenceController {
  GroupSpacingController(super.ref)
    : super(
        storageKey: groupSpacingKey,
        fallback: 0,
        normalise: (v) => groupSpacingSteps.reduce(
          (a, b) => (a - v).abs() <= (b - v).abs() ? a : b,
        ),
      );
}

final groupSpacingControllerProvider =
    StateNotifierProvider<GroupSpacingController, int>(
      GroupSpacingController.new,
    );

class UiScaleController extends IntPreferenceController {
  UiScaleController(super.ref)
    : super(
        storageKey: uiScaleKey,
        fallback: 100,
        normalise: (v) =>
            ((v.clamp(uiScaleMin, uiScaleMax)) / uiScaleStep).round() *
            uiScaleStep,
      );
}

final uiScaleControllerProvider = StateNotifierProvider<UiScaleController, int>(
  UiScaleController.new,
);

/// The factor [uiScaleControllerProvider] applies at the app root.
double uiScaleFactor(int percent) => percent / 100;
