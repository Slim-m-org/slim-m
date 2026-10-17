// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A rail section's own header label and its "+" (split out of
/// `channel_rail_sections.dart` for the review budget): shared by
/// `DirectMessagesSection` and every channel category header.
///
/// Every header renders in sentence case now, this app's own "Direct
/// messages" and "Channels" included (design review note 1). Uppercasing
/// only the app's own wording once left the rail speaking two header
/// languages: a category typed "dev" showed back exactly that, while
/// "Direct messages" shouted in caps two rows above it. The member pane's
/// "ONLINE · 3" is the one place uppercase survives, because no user-typed
/// text ever sits beside it there.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'create_channel_sheet.dart';

/// How far below a touch header's middle its hugging label centres: the
/// bottom inset plus half the label's line, off the 4dp grid for that reason.
const double _labelCentreDrop = 6;

class SectionLabel extends StatefulWidget {
  const SectionLabel(
    this.text, {
    super.key,
    this.trailingBuilder,
    this.collapsed = false,
    this.onToggle,
  });

  final String text;

  /// Null for a header that does not fold (Direct messages, the implicit
  /// uncategorised bucket); otherwise pressing the header calls it.
  final VoidCallback? onToggle;
  final bool collapsed;

  /// Builds the section's add glyph given whether it should currently show,
  /// and a callback to report the glyph's own focus back up to this header -
  /// null for a section nobody may add to. See [_SectionLabelState].
  final Widget Function(bool revealed, ValueChanged<bool> onFocusChange)?
  trailingBuilder;

  @override
  State<SectionLabel> createState() => _SectionLabelState();
}

/// Mirrors `ManagedChannelRow`'s own hover/focus reveal for its kebab: a
/// pointer hovering the header reveals the trailing glyph, a keyboard
/// reaching it does too, and touch shows it always since a finger has no
/// hover. The header itself used to always show the glyph on the theory
/// that "a header has no hover state of its own" - true of the text, not of
/// the row it sits in, which can carry one exactly like a channel row does.
class _SectionLabelState extends State<SectionLabel> {
  bool _hovered = false;
  bool _trailingFocused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (widget.text.isEmpty) return const SizedBox.shrink();
    final onToggle = widget.onToggle;
    final title = Semantics(
      container: true,
      header: true,
      label: widget.text,
      child: ExcludeSemantics(
        child: Text(
          widget.text,
          overflow: TextOverflow.ellipsis,
          style: AppText.label.copyWith(color: tokens.textSecondary),
        ),
      ),
    );
    final label = onToggle == null
        ? title
        : _FoldButton(
            collapsed: widget.collapsed,
            name: widget.text,
            onToggle: onToggle,
            child: title,
          );
    final touch = AppTouchTargets.of(context);
    final revealed = touch || _hovered || _trailingFocused;
    final trailing = widget.trailingBuilder?.call(
      revealed,
      (v) => setState(() => _trailingFocused = v),
    );
    if (touch) return _touchHeader(label, trailing);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        // Mirrors AppListRow's horizontal padding, so header and row text share a left edge.
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s8,
          AppRhythm.headingTop,
          AppSpacing.s8,
          AppRhythm.headingBottom,
        ),
        child: trailing == null
            ? label
            : Row(
                children: [
                  Expanded(child: label),
                  trailing,
                ],
              ),
      ),
    );
  }

  /// A full touch target tall, but with the text hugging its own rows, so the
  /// gap above a header reads wider than the gap below it.
  Widget _touchHeader(Widget label, Widget? trailing) {
    final hugged = widget.onToggle == null
        ? Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: label,
            ),
          )
        : label;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      child: SizedBox(
        height: AppSizes.rowTouch,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: hugged),
            if (trailing != null)
              Align(
                alignment: Alignment.bottomCenter,
                // Centres the button on the label, which sits above the box's own middle.
                child: Transform.translate(
                  offset: const Offset(0, _labelCentreDrop),
                  child: trailing,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The `+` on a section header: makes a channel already filed under that
/// section, so nobody has to create one and immediately drag it.
///
/// Hover-revealed by [SectionLabel] the same way a row's kebab is; touch
/// always shows it, since this is the only pointer-free way to create a
/// channel in a specific place - a right-click has no touch equivalent. The
/// reveal wraps only the button, inside the alignment [Padding], the same
/// nesting `ManagedChannelRow`'s own kebab uses - wrapping the padding too
/// would merge it into the button's own semantics box and throw off the
/// shared right edge `category_add_channel_test.dart` measures.
class AddChannelGlyph extends StatelessWidget {
  const AddChannelGlyph({
    super.key,
    required this.categoryId,
    required this.categoryName,
    required this.revealed,
    required this.onFocusChange,
  });

  /// Null for the implicit uncategorised section, which is what the create
  /// route already means by an absent category.
  final String? categoryId;
  final String categoryName;
  final bool revealed;
  final ValueChanged<bool> onFocusChange;

  @override
  Widget build(BuildContext context) {
    // The exact inset ChannelRow gives its kebab, from an edge already matching AppListRow's; both glyphs land on one line.
    final inset = AppTouchTargets.of(context) ? 0.0 : 4.0;
    return Padding(
      padding: EdgeInsets.only(right: inset),
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onFocusChange: onFocusChange,
        child: AnimatedOpacity(
          opacity: revealed ? 1 : 0,
          duration: AppMotion.reduced(context, AppMotion.fast),
          // Hidden from the eye is not hidden from a screen reader.
          alwaysIncludeSemantics: true,
          child: AppIconButton(
            icon: AppIcons.add,
            semanticLabel: 'Create a channel in $categoryName',
            size: AppIconButtonSize.sm,
            onPressed: () => showCreateChannelSheet(
              context,
              initialKind: 'text',
              categoryId: categoryId,
              categoryName: categoryId == null ? null : categoryName,
            ),
          ),
        ),
      ),
    );
  }
}

/// The header's press target: a chevron that turns right when folded, then
/// the name. A real focusable button so Enter and Space fold it too.
class _FoldButton extends StatelessWidget {
  const _FoldButton({
    required this.collapsed,
    required this.name,
    required this.onToggle,
    required this.child,
  });

  final bool collapsed;
  final String name;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    // No `header: true`: the web engine renders a header as a bare h2 and drops the button role, the label-less expanded state and the tap.
    return Semantics(
      container: true,
      button: true,
      expanded: !collapsed,
      label: name,
      hint: collapsed ? 'Expand' : 'Collapse',
      excludeSemantics: true,
      onTap: onToggle,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Align(
          alignment: Alignment.bottomLeft,
          heightFactor: touch ? null : 1,
          child: Padding(
            padding: EdgeInsets.only(bottom: touch ? AppSpacing.s8 : 0),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: AppMotion.reduced(context, AppMotion.fast),
                  child: Icon(
                    AppIcons.chevronDown,
                    size: AppSizes.icon16,
                    color: tokens.textSecondary,
                  ),
                ),
                const SizedBox(width: AppSpacing.s4),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
