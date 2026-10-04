// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Click-and-hold reordering of the channel rail at pointer widths.
///
/// A held press lifts a channel or a category; the item follows the pointer
/// as a floating copy, the original stays as a dimmed placeholder, and an
/// insertion line shows where release will place it. Rows never shuffle while
/// carrying. A plain click, a quick press and a short drag never lift, so
/// selecting and scrolling are untouched. `docs/design/desktop-vs-mobile.md`
/// rules 1 and 3: width picks this path, and the phone path lifts on a long
/// press too.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_rail_reorder.dart' show ChannelSection;
import 'rail_autoscroll.dart';
import 'rail_drop_slots.dart';
import 'rail_move_actions.dart';
import 'rail_carry_overlay.dart';
import 'rail_carry_slot.dart';

const _holdDelay = Duration(milliseconds: 300);

class DesktopRailReorder extends StatefulWidget {
  const DesktopRailReorder({
    super.key,
    required this.sections,
    required this.collapsed,
    required this.rowBuilder,
    required this.carriedRowBuilder,
    required this.headerBuilder,
    this.carriedHeaderBuilder,
    this.carriedRowInset = 0,
    required this.onReorder,
    required this.onReorderCategories,
  });

  final List<ChannelSection> sections;
  final Set<String> collapsed;
  final Widget Function(Channel channel, bool longPressDrags) rowBuilder;

  /// Builds the floating copy, which cannot reuse the original's global keys.
  final Widget Function(Channel channel)? carriedRowBuilder;
  final double carriedRowInset;
  final Widget Function(ChannelCategoryRow? category)? carriedHeaderBuilder;
  final Widget Function(ChannelCategoryRow? category) headerBuilder;
  final ValueChanged<List<ChannelOrderGroup>> onReorder;
  final ValueChanged<List<String>>? onReorderCategories;

  @override
  State<DesktopRailReorder> createState() => _DesktopRailReorderState();
}

class _Carry {
  _Carry({
    required this.id,
    required this.isCategory,
    required this.grab,
    required this.size,
    required this.entry,
  });

  final String id;
  final bool isCategory;
  final Offset grab;
  final Size size;
  final OverlayEntry entry;
  DropSlot? slot;
}

class _DesktopRailReorderState extends State<DesktopRailReorder>
    with SingleTickerProviderStateMixin {
  final _stackKey = GlobalKey();
  final _link = LayerLink();
  final _slot = ValueNotifier<DropSlot?>(null);
  final _boxKeys = <String, GlobalKey>{};
  final _pointer = ValueNotifier<Offset>(Offset.zero);
  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: AppMotion.base,
  );
  _Carry? _carry;
  Timer? _scrollTimer;

  GlobalKey _keyFor(String id) => _boxKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void dispose() {
    _stopCarry();
    _lift.dispose();
    _pointer.dispose();
    _slot.dispose();
    super.dispose();
  }

  List<String> get _categoryIds => [
    for (final (category, _) in widget.sections)
      if (category != null) category.id,
  ];

  @override
  Widget build(BuildContext context) {
    final carry = _carry;
    if (carry != null) WidgetsBinding.instance.addPostFrameCallback(_retarget);
    return CompositedTransformTarget(
      link: _link,
      child: Column(
        key: _stackKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var s = 0; s < widget.sections.length; s++) ..._section(s),
        ],
      ),
    );
  }

  List<Widget> _section(int s) {
    final (category, channels) = widget.sections[s];
    final carry = _carry;
    final foldedAway =
        carry != null && carry.isCategory && carry.id == category?.id;
    return [
      _item(
        id: 'h:${category?.id}',
        dimmed: foldedAway,
        liftable: category != null,
        isCategory: true,
        liftId: category?.id ?? '',
        actions: category == null
            ? const {}
            : categoryMoveActions(
                _categoryIds,
                category.id,
                widget.onReorderCategories,
              ),
        child: widget.headerBuilder(category),
      ),
      for (final channel in channels)
        foldedAway
            ? KeyedSubtree(
                key: _keyFor('c:${channel.id}'),
                child: const SizedBox.shrink(),
              )
            : _item(
                id: 'c:${channel.id}',
                dimmed: carry?.id == channel.id && !carry!.isCategory,
                liftable: true,
                isCategory: false,
                liftId: channel.id,
                actions: channelMoveActions(
                  WidgetsLocalizations.of(context),
                  widget.sections,
                  widget.collapsed,
                  channel.id,
                  widget.onReorder,
                ),
                child: widget.rowBuilder(channel, true),
              ),
    ];
  }

  Widget _item({
    required String id,
    required bool dimmed,
    required bool liftable,
    required bool isCategory,
    required String liftId,
    required Map<CustomSemanticsAction, VoidCallback> actions,
    required Widget child,
  }) {
    Widget item = Semantics(
      customSemanticsActions: actions,
      child: dimmed ? _slotFor(isCategory) : child,
    );
    if (liftable) {
      item = RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: _holdDelay),
                (r) => r
                  ..onLongPressStart = ((d) =>
                      _liftItem(id, liftId, isCategory, d.globalPosition))
                  ..onLongPressMoveUpdate = ((d) => _move(d.globalPosition))
                  ..onLongPressEnd = ((d) => _drop(d.globalPosition))
                  ..onLongPressCancel = _cancel,
              ),
        },
        child: item,
      );
    }
    return KeyedSubtree(key: _keyFor(id), child: item);
  }

  Widget _slotFor(bool isCategory) => RailCarrySlot(
    height: _carry!.size.height,
    inset: isCategory ? 0 : widget.carriedRowInset,
  );

  RenderBox? _boxOf(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  List<RailBox> _measure(RenderBox stack) {
    final boxes = <RailBox>[];
    for (var s = 0; s < widget.sections.length; s++) {
      final (category, channels) = widget.sections[s];
      void add(RailBoxKind kind, String id) {
        final box = _boxOf(_keyFor(id));
        if (box == null) return;
        final top = stack.globalToLocal(box.localToGlobal(Offset.zero)).dy;
        boxes.add(
          RailBox(
            kind: kind,
            section: s,
            top: top,
            bottom: top + box.size.height,
          ),
        );
      }

      add(RailBoxKind.header, 'h:${category?.id}');
      for (final channel in channels) {
        add(RailBoxKind.channel, 'c:${channel.id}');
      }
    }
    return boxes;
  }

  void _liftItem(String id, String liftId, bool isCategory, Offset global) {
    if (_carry != null) return;
    final box = _boxOf(_keyFor(id));
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);
    final overlay = Overlay.of(context);
    late final _Carry carry;
    final entry = OverlayEntry(builder: (_) => _floating(carry));
    carry = _Carry(
      id: liftId,
      isCategory: isCategory,
      grab: global - origin,
      size: box.size,
      entry: entry,
    );
    _pointer.value = global;
    overlay.insert(entry);
    HardwareKeyboard.instance.addHandler(_onKey);
    _scrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScroll(),
    );
    AppHaptics.impact();
    setState(() => _carry = carry);
    _lift.forward(from: 0);
  }

  Widget _floating(_Carry carry) {
    final copy = carry.isCategory
        ? (widget.carriedHeaderBuilder ?? widget.headerBuilder)(
            widget.sections
                .map((s) => s.$1)
                .firstWhere((c) => c?.id == carry.id, orElse: () => null),
          )
        : _carriedRow(carry.id);
    return InheritedTheme.captureAll(
      context,
      RailCarryOverlay(
        copy: copy,
        pointer: _pointer,
        slot: _slot,
        grab: carry.grab,
        size: carry.size,
        inset: carry.isCategory ? 0 : widget.carriedRowInset,
        lift: _lift,
        link: _link,
        listWidth: () => _boxOf(_stackKey)?.size.width ?? 0,
      ),
    );
  }

  Widget _carriedRow(String channelId) {
    final channel = [
      for (final (_, channels) in widget.sections) ...channels,
    ].firstWhere((c) => c.id == channelId);
    return widget.carriedRowBuilder?.call(channel) ??
        widget.rowBuilder(channel, true);
  }

  void _move(Offset global) {
    if (_carry == null) return;
    _pointer.value = global;
    _retarget();
  }

  void _retarget([Object? _]) {
    final carry = _carry;
    final stack = _boxOf(_stackKey);
    if (carry == null || stack == null || !mounted) return;
    final y = stack.globalToLocal(_pointer.value).dy;
    final boxes = _measure(stack);
    final slot = carry.isCategory
        ? categorySlotAt(boxes, _namedSections(), y)
        : channelSlotAt(boxes, _closedSections(), y);
    if (slot == carry.slot) return;
    carry.slot = slot;
    _slot.value = slot;
  }

  List<int> _namedSections() => [
    for (var s = 0; s < widget.sections.length; s++)
      if (widget.sections[s].$1 != null) s,
  ];

  Set<int> _closedSections() => {
    for (var s = 0; s < widget.sections.length; s++)
      if (widget.collapsed.contains(widget.sections[s].$1?.id)) s,
  };

  void _autoScroll() {
    if (autoScrollRail(context, _pointer.value.dy)) _retarget();
  }

  bool _onKey(KeyEvent event) {
    if (_carry == null ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _cancel();
    return true;
  }

  void _drop(Offset global) {
    final carry = _carry;
    if (carry == null) return;
    _pointer.value = global;
    _retarget();
    final slot = carry.slot;
    _endCarry();
    if (slot == null) return;
    if (carry.isCategory) {
      final next = categoryIdsAfterDrop(_categoryIds, carry.id, slot.index);
      if (next != null) widget.onReorderCategories?.call(next);
      return;
    }
    final groups = groupsAfterDrop(widget.sections, carry.id, slot);
    if (groups != null) widget.onReorder(groups);
  }

  void _cancel() {
    if (_carry != null) _endCarry();
  }

  void _endCarry() {
    _stopCarry();
    AppHaptics.selection();
    _slot.value = null;
    if (mounted) setState(() => _carry = null);
  }

  void _stopCarry() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    HardwareKeyboard.instance.removeHandler(_onKey);
    final carry = _carry;
    if (carry == null) return;
    carry.entry
      ..remove()
      ..dispose();
  }
}
