// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette's visual parts, shared by the floating card and the
/// compact sheet so both widths draw identical rows: section headers, the
/// four row kinds, the footer and the search field's Esc keycap.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'channel_kind_icon.dart';
import 'command_palette_items.dart';
import 'message_row_identity.dart' show formatMessageDay;
import 'user_avatar.dart';

/// [text] with the first case-insensitive occurrence of [query] in bold.
List<InlineSpan> paletteHighlightSpans(String text, String query) {
  final at = query.isEmpty
      ? -1
      : text.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0) return [TextSpan(text: text)];
  final end = at + query.length;
  return [
    if (at > 0) TextSpan(text: text.substring(0, at)),
    TextSpan(
      text: text.substring(at, end),
      style: const TextStyle(fontWeight: AppWeights.semi),
    ),
    if (end < text.length) TextSpan(text: text.substring(end)),
  ];
}

Widget _highlighted(
  String text,
  String query,
  TextStyle style, {
  int maxLines = 1,
}) => Text.rich(
  TextSpan(children: paletteHighlightSpans(text, query)),
  style: style,
  maxLines: maxLines,
  overflow: TextOverflow.ellipsis,
);

/// An uppercase mono section name with its right-aligned result count.
class PaletteSectionHeader extends StatelessWidget {
  const PaletteSectionHeader({
    super.key,
    required this.label,
    required this.count,
  });

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.code.copyWith(
      fontSize: AppText.micro.fontSize,
      letterSpacing: AppText.micro.fontSize! * 0.06,
      color: tokens.textSecondary,
    );
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          10,
          AppSpacing.s12,
          10,
          AppSpacing.s4,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                semanticsLabel: label,
                style: style,
              ),
            ),
            Text('$count', style: style.copyWith(color: tokens.textDisabled)),
          ],
        ),
      ),
    );
  }
}

/// One tappable palette row: the highlight fill, the current-channel accent
/// bar on the left and the Enter keycap on the highlighted row.
class PaletteRowShell extends StatefulWidget {
  const PaletteRowShell({
    super.key,
    required this.child,
    required this.highlighted,
    required this.touch,
    required this.onTap,
    this.current = false,
    this.semanticLabel,
  });

  final Widget child;
  final bool highlighted;
  final bool touch;
  final bool current;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  State<PaletteRowShell> createState() => _PaletteRowShellState();
}

class _PaletteRowShellState extends State<PaletteRowShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final keycap = widget.highlighted && !widget.touch;
    return Semantics(
      button: true,
      selected: widget.highlighted,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Stack(
            children: [
              Container(
                constraints: BoxConstraints(
                  minHeight: widget.touch
                      ? AppSizes.rowTouch
                      : AppSizes.controlLg,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: AppSpacing.s4,
                ),
                decoration: BoxDecoration(
                  color: widget.highlighted || _hovered
                      ? tokens.surfaceSunken
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Row(
                  spacing: AppSpacing.s12,
                  children: [
                    Expanded(child: ExcludeSemantics(child: widget.child)),
                    if (keycap) const AppKbd('↵'),
                  ],
                ),
              ),
              if (widget.current)
                Positioned(
                  left: 0,
                  top: AppSpacing.s4,
                  bottom: AppSpacing.s4,
                  child: Container(
                    key: const Key('palette-current-bar'),
                    width: 3,
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      borderRadius: BorderRadius.circular(AppRadii.full),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws [item] by its kind, with [query] bolded wherever it matched.
class PaletteResultRow extends StatelessWidget {
  const PaletteResultRow({
    super.key,
    required this.item,
    required this.query,
    required this.highlighted,
    required this.touch,
    required this.onTap,
  });

  final PaletteResultItem item;
  final String query;
  final bool highlighted;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final body = switch (item.kind) {
      PaletteKind.channel => _channel(tokens),
      PaletteKind.person => _person(tokens),
      PaletteKind.message => _message(tokens),
      PaletteKind.action => _action(tokens),
    };
    return PaletteRowShell(
      highlighted: highlighted,
      touch: touch,
      current: item.isCurrent,
      semanticLabel: item.semanticLabel ?? item.label,
      onTap: onTap,
      child: body,
    );
  }

  Widget _channel(AppTokens tokens) {
    final channel = item.channel!;
    final glyph = channel.kind == 'voice' || channel.kind == 'text'
        ? ChannelKindIcon(
            isVoice: channel.kind == 'voice',
            restricted: channel.restricted ?? false,
            color: tokens.textSecondary,
          )
        : Icon(
            AppIcons.account,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          );
    return Row(
      spacing: AppSpacing.s12,
      children: [
        glyph,
        Expanded(
          child: _highlighted(
            item.label,
            query,
            AppText.ui.copyWith(color: tokens.textPrimary),
          ),
        ),
        if (item.isCurrent)
          Text(
            "You're here",
            style: AppText.caption.copyWith(color: tokens.accent),
          ),
        if (item.categoryName != null)
          Flexible(
            child: Text(
              item.categoryName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.code.copyWith(
                fontSize: AppText.caption.fontSize,
                color: tokens.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _person(AppTokens tokens) {
    final member = item.member!;
    final reason = item.reason;
    return Row(
      spacing: AppSpacing.s12,
      children: [
        UserAvatar.known(
          userId: member.id,
          avatarUpdatedAt: member.avatarUpdatedAt,
          name: member.displayName,
          size: AppAvatarSize.s28,
          presence: true,
        ),
        Flexible(
          child: _highlighted(
            item.label,
            query,
            AppText.ui.copyWith(color: tokens.textPrimary),
          ),
        ),
        if (member.isBot)
          const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
        const Spacer(),
        if (reason != null)
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${reason.label}: '),
                  ...paletteHighlightSpans(reason.value, query),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _message(AppTokens tokens) {
    final message = item.message!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s12,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            AppIcons.chat,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _highlighted(
                item.label,
                query,
                AppText.ui.copyWith(color: tokens.textPrimary),
              ),
              PaletteMessageMeta(
                message: message,
                channelLabel: item.messageChannelLabel ?? 'a channel',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _action(AppTokens tokens) => Row(
    spacing: AppSpacing.s12,
    children: [
      if (item.leading != null)
        Icon(item.leading, size: AppSizes.icon16, color: tokens.textSecondary),
      Expanded(
        child: _highlighted(
          item.label,
          query,
          AppText.ui.copyWith(color: tokens.textPrimary),
        ),
      ),
    ],
  );
}

/// A message hit's second line: author, channel and day.
class PaletteMessageMeta extends StatelessWidget {
  const PaletteMessageMeta({
    super.key,
    required this.message,
    required this.channelLabel,
  });

  final api.Message message;
  final String channelLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.code.copyWith(
      fontSize: AppText.caption.fontSize,
      color: tokens.textSecondary,
    );
    final day = formatMessageDay(message.createdAt);
    return Row(
      children: [
        PaletteMessageAuthor(
          authorId: message.authorId,
          cachedDisplayName: message.authorDisplayName,
          style: style,
        ),
        Flexible(
          child: Text(
            ' in $channelLabel \u00B7 $day',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// The search field's trailing Esc keycap; tapping it closes the palette.
class PaletteEscKeycap extends StatelessWidget {
  const PaletteEscKeycap({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const Key('palette-esc'),
    onTap: onTap,
    child: const MouseRegion(
      cursor: SystemMouseCursors.click,
      child: AppKbd('Esc'),
    ),
  );
}

/// The floating card's footer: the keys that move through results, and the
/// prefixes that narrow them. Desktop only, since a phone has no such keys.
class PaletteFooter extends StatelessWidget {
  const PaletteFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final hintStyle = AppText.caption.copyWith(color: tokens.textSecondary);
    Widget hint(List<String> keys, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s4,
      children: [
        for (final key in keys) AppKbd(key),
        Text(label, style: hintStyle),
      ],
    );
    Widget prefixHint(String glyph, String label) => Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: glyph,
            style: AppText.code.copyWith(color: tokens.textPrimary),
          ),
          TextSpan(text: ' $label'),
        ],
      ),
      style: hintStyle,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: AppSpacing.s16,
              runSpacing: AppSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                hint(const ['↑', '↓'], 'Move'),
                hint(const ['Enter'], 'Open'),
                hint(const ['Tab'], 'Next section'),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          prefixHint('#', 'channels'),
          const SizedBox(width: AppSpacing.s12),
          prefixHint('@', 'people'),
        ],
      ),
    );
  }
}
