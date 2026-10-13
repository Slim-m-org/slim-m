// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet shown once after an update: what changed since whichever
/// version was last seen on this install.
///
/// This is `desktop-vs-mobile.md` rule 4, a short task with a single
/// dismiss: [showAppSheet] renders it as a bottom sheet under the compact
/// breakpoint and a centered dialog above it, with the same [entries]
/// content either way.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../whats_new/whats_new_content.dart';
import 'release_notes_entry.dart';

/// Marks the sizing box around the sheet's body, so a test can measure it
/// directly rather than inferring the fix from a screenshot - the same
/// technique `pinnedMessagesBodyBoxKey` uses.
const whatsNewBodyBoxKey = Key('whats_new_body_box');
const whatsNewScrollRuleKey = Key('whats_new_scroll_rule');

/// The most of the window the body may take, and the most it may take at all.
///
/// The fraction alone is right on a phone and wrong on a monitor: the taller
/// the screen the taller the dialog, so 0.6 of a 1440-tall window gave a
/// 460-wide box 864 tall - nearly twice as tall as wide, which is a phone
/// screen stretched rather than a desktop dialog. `desktop-vs-mobile.md`
/// rule 4 fixes the width at 460 and says nothing about height, so the
/// ceiling is this file's to choose; 560 keeps the proportions upright at
/// every size this ships at while leaving the phone sheet exactly as it was.
double _bodyCeiling(BuildContext context) {
  final fraction = MediaQuery.sizeOf(context).height * 0.6;
  return fraction < _maxBodyHeight ? fraction : _maxBodyHeight;
}

const double _maxBodyHeight = 560;

/// Shows [entries], newest first: someone catching up after skipping a few
/// releases cares most about the latest, and [entries] itself is kept in the
/// chronological order it was authored in so this is the one place that
/// reverses it for display.
Future<void> showWhatsNewSheet(
  BuildContext context,
  List<WhatsNewEntry> entries,
) {
  return showAppSheet<void>(
    context,
    scrolls: true,
    builder: (context) => _NotesSheet(
      title: "What's new",
      buttonLabel: 'Got it',
      entries: entries.reversed.toList(growable: false),
      collapsible: false,
    ),
  );
}

/// Shows every release, newest first, with the latest open and the rest folded.
Future<void> showReleaseNotesSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    scrolls: true,
    builder: (context) => _NotesSheet(
      title: 'Release notes',
      buttonLabel: 'Close',
      entries: whatsNewEntries.reversed.toList(growable: false),
      collapsible: true,
    ),
  );
}

class _NotesSheet extends StatelessWidget {
  const _NotesSheet({
    required this.title,
    required this.buttonLabel,
    required this.entries,
    required this.collapsible,
  });

  final String title;
  final String buttonLabel;
  final List<WhatsNewEntry> entries;
  final bool collapsible;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // A ceiling, not a fixed size: short entries must not force a dialog tall enough for a maximum-length one.
    return ConstrainedBox(
      key: whatsNewBodyBoxKey,
      constraints: BoxConstraints(maxHeight: _bodyCeiling(context)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          0,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  AppIcons.highlight,
                  size: AppSizes.icon20,
                  color: tokens.accent,
                ),
                const SizedBox(width: AppSpacing.s8),
                Flexible(
                  child: Text(
                    title,
                    style: AppText.heading.copyWith(color: tokens.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s16),
            Flexible(
              child: _ScrollWithEdge(
                borderColor: tokens.borderSubtle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < entries.length; i++) ...[
                      if (i > 0) _EntryDivider(color: tokens.borderSubtle),
                      collapsible
                          ? _FoldingEntry(
                              entry: entries[i],
                              initiallyOpen: i == 0,
                            )
                          : _OpenEntry(entry: entries[i]),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: buttonLabel,
              variant: AppButtonVariant.primary,
              full: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// A scrolling body that shows its scrollbar and a rule above the pinned action while more waits below.
class _ScrollWithEdge extends StatefulWidget {
  const _ScrollWithEdge({required this.child, required this.borderColor});

  final Widget child;
  final Color borderColor;

  @override
  State<_ScrollWithEdge> createState() => _ScrollWithEdgeState();
}

class _ScrollWithEdgeState extends State<_ScrollWithEdge> {
  final _controller = ScrollController();
  bool _moreBelow = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _update(ScrollMetrics m) {
    final more = m.extentAfter > 1;
    if (more != _moreBelow) setState(() => _moreBelow = more);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) => _update(n.metrics),
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) => _update(n.metrics),
              child: Scrollbar(
                controller: _controller,
                thumbVisibility: _moreBelow,
                child: SingleChildScrollView(
                  controller: _controller,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
        if (_moreBelow) ...[
          const SizedBox(height: AppSpacing.s8),
          Divider(
            key: whatsNewScrollRuleKey,
            height: 1,
            thickness: 1,
            color: widget.borderColor,
          ),
        ],
      ],
    );
  }
}

class _EntryDivider extends StatelessWidget {
  const _EntryDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.s12),
    child: Divider(height: 1, thickness: 1, color: color),
  );
}

class _OpenEntry extends StatelessWidget {
  const _OpenEntry({required this.entry});

  final WhatsNewEntry entry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReleaseNotesHeading(entry: entry),
        const SizedBox(height: AppSpacing.s12),
        ReleaseNotesPoints(entry: entry),
      ],
    );
  }
}

/// A version whose points fold away, so the history stays scannable.
class _FoldingEntry extends StatefulWidget {
  const _FoldingEntry({required this.entry, required this.initiallyOpen});

  final WhatsNewEntry entry;
  final bool initiallyOpen;

  @override
  State<_FoldingEntry> createState() => _FoldingEntryState();
}

class _FoldingEntryState extends State<_FoldingEntry> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          onTap: () => setState(() => _open = !_open),
          label: 'Version ${widget.entry.version}, ${widget.entry.headline}',
          child: ExcludeSemantics(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadii.control),
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
                child: Row(
                  children: [
                    Expanded(child: ReleaseNotesHeading(entry: widget.entry)),
                    const SizedBox(width: AppSpacing.s8),
                    Icon(
                      _open ? AppIcons.chevronUp : AppIcons.chevronDown,
                      size: AppSizes.icon16,
                      color: tokens.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: AppSpacing.s12),
          ReleaseNotesPoints(entry: widget.entry),
        ],
      ],
    );
  }
}
