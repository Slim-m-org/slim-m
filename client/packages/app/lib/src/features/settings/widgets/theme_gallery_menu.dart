// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A gallery card's menu: what each kind of theme offers, who may set the
/// Space default or remove a theme, the title a phone's sheet opens with, and
/// the confirms before Delete and Remove.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../widgets/confirm_dialog.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_gallery.dart';
import '../providers/theme_gallery_actions.dart';
import 'theme_gallery_frame.dart';
import 'theme_miniature.dart';

/// Builds each card's menu items and sheet title.
class ThemeGalleryMenu {
  const ThemeGalleryMenu({
    required this.actions,
    required this.me,
    required this.openEditor,
  });

  final ThemeGalleryActions actions;
  final api.Me? me;
  final ValueChanged<ThemeEditorSeed> openEditor;

  static const confirmKey = Key('theme-confirm');

  bool get _manages =>
      me?.permissions.hasPermission(Perm.manageServer) ?? false;

  bool _mayRemove(ThemeGalleryEntry entry) =>
      _manages || (me != null && entry.authorId == me!.id);

  /// Null for a card with nothing beyond applying it.
  List<Widget> Function(BuildContext, VoidCallback)? itemsFor(
    ThemeGalleryEntry entry,
  ) {
    if (entry.kind == ThemeGalleryKind.builtIn) {
      final seed = customiseSeed(entry.choice!);
      if (seed == null) return null;
      return (context, close) => [
        _item('Customise', AppIcons.edit, close, () => openEditor(seed)),
      ];
    }
    return (context, close) => switch (entry.kind) {
      ThemeGalleryKind.mine => _mine(context, entry, close),
      ThemeGalleryKind.unsaved => _unsaved(entry, close),
      _ => _space(context, entry, close),
    };
  }

  List<Widget> _mine(
    BuildContext context,
    ThemeGalleryEntry entry,
    VoidCallback close,
  ) {
    final document = entry.document!;
    return [
      _item(
        'Edit',
        AppIcons.edit,
        close,
        () => openEditor(ThemeEditorSeed(document, mineId: entry.id)),
      ),
      _item(
        'Publish to Space',
        AppIcons.share,
        close,
        () => actions.publish(document),
      ),
      _item(
        'Export to file',
        AppIcons.download,
        close,
        () => actions.export(document),
      ),
      const AppMenuDivider(),
      _item('Delete', AppIcons.delete, close, danger: true, () async {
        final sure = await confirmChoice(
          context,
          title: 'Delete ${entry.name}?',
          message: 'It is removed from this device.',
          confirmLabel: 'Delete',
          confirmVariant: AppButtonVariant.danger,
          confirmKey: confirmKey,
        );
        if (sure) await actions.delete(entry.id!);
      }),
    ];
  }

  List<Widget> _unsaved(ThemeGalleryEntry entry, VoidCallback close) {
    final document = entry.document!;
    return [
      _item(
        'Save to Mine',
        AppIcons.check,
        close,
        () => actions.saveToMine(document),
      ),
      _item(
        'Publish to Space',
        AppIcons.share,
        close,
        () => actions.publish(document),
      ),
      _item(
        'Export to file',
        AppIcons.download,
        close,
        () => actions.export(document),
      ),
    ];
  }

  List<Widget> _space(
    BuildContext context,
    ThemeGalleryEntry entry,
    VoidCallback close,
  ) {
    final copy = editCopySeed(entry);
    final remove = _mayRemove(entry);
    final defaults = _manages && (entry.broken == null || entry.isSpaceDefault);
    return [
      if (copy != null)
        _item('Edit a copy', AppIcons.copy, close, () => openEditor(copy)),
      if (defaults)
        entry.isSpaceDefault
            ? _item(
                'Clear default',
                AppIcons.pin,
                close,
                () => actions.setDefault(null),
              )
            : _item(
                'Set as Space default',
                AppIcons.pin,
                close,
                () => actions.setDefault(entry.id),
              ),
      if (remove) ...[
        if (copy != null || defaults) const AppMenuDivider(),
        _item('Remove', AppIcons.delete, close, danger: true, () async {
          final sure = await confirmChoice(
            context,
            title: 'Remove ${entry.name} for everyone?',
            message: 'People using it keep their copy.',
            confirmLabel: 'Remove',
            confirmVariant: AppButtonVariant.danger,
            confirmKey: confirmKey,
          );
          if (sure) await actions.remove(entry.id!);
        }),
      ],
    ];
  }

  Widget _item(
    String label,
    IconData icon,
    VoidCallback close,
    FutureOr<void> Function() run, {
    bool danger = false,
  }) => AppMenuItem(
    label: label,
    leading: icon,
    tone: danger ? AppMenuItemTone.danger : AppMenuItemTone.normal,
    onTap: () {
      close();
      unawaited(Future.sync(run));
    },
  );

  /// What a phone's sheet names: a thumbnail, the theme, where it is from.
  Widget sheetHeader(BuildContext context, ThemeGalleryEntry entry) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final author = entry.author == null ? '' : ' · by ${entry.author}';
    final caption = switch (entry.kind) {
      ThemeGalleryKind.builtIn => 'Built in',
      ThemeGalleryKind.mine => 'Mine',
      ThemeGalleryKind.unsaved => 'Not saved',
      ThemeGalleryKind.space =>
        '${entry.isSpaceDefault ? 'Space default' : 'Space'}$author',
    };
    final miniature = entry.tokens;
    final broken = entry.broken;
    final header = AppSheetHeader(
      entry.name,
      caption: caption,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s8,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      leading: SizedBox(
        width: 48,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(3),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: broken != null || miniature == null
                ? ThemeBrokenPlaceholder(
                    broken: broken ?? ThemeBroken.unreadable,
                    compact: true,
                  )
                : ThemeMiniature(
                    tokens: miniature,
                    brightness: entry.brightness,
                    split: entry.split,
                  ),
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        ColoredBox(
          color: tokens.borderSubtle,
          child: const SizedBox(height: 1),
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }
}
