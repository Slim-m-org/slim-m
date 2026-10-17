// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two touch-reachable entry points into the emoji picker, split out of
/// `emoji_picker.dart` to keep that file inside the review budget.
///
/// [showEmojiPickerSheet] wraps the same [EmojiPickerPanel] `EmojiPickerButton`
/// opens, the touch counterpart to its hover-anchored overlay.
/// [showSpaceEmojiSheet] is the composer's own, narrower entry point: the
/// Space's own emoji and nothing else, since a composer already has the
/// phone's keyboard behind it for every native one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../providers/recent_emoji.dart';
import 'emoji_catalog.dart';
import 'emoji_picker_grid.dart';
import 'emoji_picker_panel.dart';

/// The horizontal breathing room a sheet leaves on each side, so the panel's
/// own border never sits flush against the screen edge.
const double _sheetInset = AppSpacing.s8;

/// Opens the picker as a bottom sheet: the touch-reachable counterpart to
/// `EmojiPickerButton`'s hover-anchored overlay, wrapping the same panel
/// rather than a second implementation of it.
///
/// [onSelect] runs after the sheet has popped, so a caller that moves focus
/// (the composer re-focusing its field) is not fighting the closing route.
Future<void> showEmojiPickerSheet(
  BuildContext context, {
  required ValueChanged<String> onSelect,
}) {
  return _sheet(
    context,
    // The width the sheet has, not the desktop popup's 320, or a phone wastes a third of it.
    (context, width) => EmojiPickerPanel(
      autofocusSearch: false,
      width: width,
      onSelect: (emoji) {
        Navigator.of(context).pop();
        onSelect(emoji);
      },
      onClose: () => Navigator.of(context).pop(),
    ),
  );
}

/// Opens the composer's emoji entry point: the Space's own emoji, and only
/// those. A Space with none says so rather than opening an empty grid.
///
/// [onSelect] runs after the sheet has popped, matching
/// [showEmojiPickerSheet], so the composer's re-focus is not fighting the
/// closing route.
Future<void> showSpaceEmojiSheet(
  BuildContext context, {
  required ValueChanged<String> onSelect,
}) {
  return _sheet(
    context,
    (context, width) => SizedBox(
      width: width,
      child: SpaceEmojiSheetBody(
        onSelect: (emoji) {
          Navigator.of(context).pop();
          onSelect(emoji);
        },
      ),
    ),
  );
}

/// The shape both sheets share: keyboard-inset aware, safe-area aware, and
/// measured so its child is handed the width it really has.
Future<void> _sheet(
  BuildContext context,
  Widget Function(BuildContext context, double width) build,
) {
  return showAppSheet<void>(
    context,
    maxWidth: 520,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        left: _sheetInset,
        right: _sheetInset,
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      // Inside the keyboard inset, cancelling the route's own top padding.
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, constraints) =>
                  build(context, constraints.maxWidth),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The Space's own emoji as a grid, with a plain sentence in place of every
/// state that has nothing to show: still loading, unreachable, or genuinely
/// none uploaded yet.
/// The Space's own emoji list, exposed so the composer's tabbed touch sheet
/// can host it under an Emoji tab beside a GIFs one.
///
/// Deliberately this and not `ComposerEmojiPicker`, which the pointer panel
/// uses: that carries the whole unicode catalog and a search, and a phone
/// already has both under the field in its own keyboard. Combining the two
/// pickers on touch was asked for; duplicating the keyboard was not.
class SpaceEmojiSheetBody extends ConsumerStatefulWidget {
  const SpaceEmojiSheetBody({super.key, required this.onSelect});

  final ValueChanged<String> onSelect;

  @override
  ConsumerState<SpaceEmojiSheetBody> createState() =>
      _SpaceEmojiSheetBodyState();
}

class _SpaceEmojiSheetBodyState extends ConsumerState<SpaceEmojiSheetBody> {
  final _search = TextEditingController();

  /// A ceiling, not a height: a Space with four emoji gets one row.
  static const double _maxGridHeight = 260;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(PickerEmoji emoji) {
    ref.read(recentEmojiProvider.notifier).use(emoji.token);
    widget.onSelect(emoji.token);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final custom = ref.watch(customEmojiProvider);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: switch (custom) {
        AsyncError() => const _SheetMessage(
          'Could not load the emoji for this Space.',
        ),
        AsyncData(value: final List<CustomEmoji> emoji) when emoji.isEmpty =>
          const _SheetMessage(
            'This Space has no custom emoji yet. Native emoji are on your '
            'keyboard.',
          ),
        AsyncData(value: final List<CustomEmoji> emoji) => _column(tokens, [
          for (final e in emoji)
            if (emojiNameMatches(e.name, _search.text)) e,
        ]),
        _ => const _SheetMessage('Loading the emoji for this Space...'),
      },
    );
  }

  Widget _column(AppTokens tokens, List<CustomEmoji> shown) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s12,
          0,
          AppSpacing.s12,
          AppSpacing.s8,
        ),
        child: Text(
          'Space emoji',
          style: AppText.label.copyWith(color: tokens.textSecondary),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s8,
          0,
          AppSpacing.s8,
          AppSpacing.s8,
        ),
        child: AppInput(
          controller: _search,
          placeholder: 'Search Space emoji',
          semanticLabel: 'Search Space emoji',
          icon: Icon(
            AppIcons.search,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      if (shown.isEmpty)
        _SheetMessage('No emoji match "${_search.text.trim()}".')
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _maxGridHeight),
          child: EmojiGrid(
            shrinkWrap: true,
            emoji: [for (final e in shown) DeploymentEmoji(e)],
            // No keyboard navigation in a sheet, so nothing is on deck.
            highlighted: -1,
            onTap: _pick,
          ),
        ),
    ],
  );
}

/// One centered sentence, for a sheet with no grid to draw.
class _SheetMessage extends StatelessWidget {
  const _SheetMessage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s24,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppText.body.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}
