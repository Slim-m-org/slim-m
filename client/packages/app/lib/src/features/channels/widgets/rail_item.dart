// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'rail_drop_slots.dart';

/// The item a held press lifted, with its floating copy and current drop slot.
class RailCarry {
  RailCarry({
    required this.id,
    required this.isCategory,
    required this.grab,
    required this.size,
    required this.inset,
    required this.entry,
  });

  final String id;
  final bool isCategory;
  final Offset grab;
  final Size size;

  /// The gap left of the lifted item's face, by its depth.
  final double inset;
  final OverlayEntry entry;
  DropSlot? slot;
}

/// What one rail row needs to be lifted, moved and announced.
class RailItem {
  const RailItem({
    required this.id,
    required this.dimmed,
    required this.liftable,
    required this.isCategory,
    required this.liftId,
    required this.inset,
    required this.actions,
    this.shortcuts = const {},
    required this.child,
  });

  final String id;
  final bool dimmed;
  final bool liftable;
  final bool isCategory;
  final String liftId;

  /// The gap left of the item's face, which its carried copy and slot keep.
  final double inset;
  final Map<CustomSemanticsAction, VoidCallback> actions;
  final Map<ShortcutActivator, VoidCallback> shortcuts;
  final Widget child;
}
