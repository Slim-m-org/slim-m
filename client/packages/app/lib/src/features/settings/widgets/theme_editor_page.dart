// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor (decision 0106), a page above Themes in the Appearance
/// pane at every width: the draft's preview pinned under the header, one
/// column of cards, and one pinned footer that saves.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/my_themes.dart';
import '../providers/stored_theme.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_file_io.dart';
import '../providers/theme_links.dart';
import '../providers/theme_source.dart';
import '../providers/theme_store_actions.dart';
import 'settings_info_line.dart';
import 'settings_sub_pages.dart';
import 'theme_colour_panel.dart';
import 'theme_contrast_panel.dart';
import 'theme_editor_details.dart';
import 'theme_editor_footer.dart';
import 'theme_editor_menu.dart';
import 'theme_main_colours.dart';
import 'theme_miniature.dart';
import 'theme_token_grid.dart';
import 'theme_token_groups_compact.dart';

/// Content this wide opens pickers inline and lays All colours out in tiles.
const _roomyFrom = 480.0;

/// A page this tall keeps the preview pinned; a shorter one scrolls it away
/// so the colours keep room.
const _pinFrom = 600.0;

/// The editor above Themes; a null [seed] is a new theme, the one
/// `?page=new-theme` opens.
SettingsSubPage themeEditorSubPage(ThemeEditorSeed? seed) => SettingsSubPage(
  id: 'theme-editor',
  title: seed?.mineId == null ? 'New theme' : 'Edit theme',
  backLabel: 'Back to Themes',
  urlId: seed == null ? 'new-theme' : null,
  ownsHeader: true,
  builder: (_) => ThemeEditorPage(seed: seed),
);

class ThemeEditorPage extends ConsumerStatefulWidget {
  const ThemeEditorPage({super.key, this.seed});

  /// What to edit; a new theme that starts as a copy of Dark when null.
  final ThemeEditorSeed? seed;

  @override
  ConsumerState<ThemeEditorPage> createState() => _ThemeEditorPageState();
}

/// Which card an inline picker opened in: Accent is in both.
enum _Place { main, grid }

typedef _OpenPicker = ({
  String token,
  _Place place,
  ThemeDraftMark mark,
  String? note,
});

class _ThemeEditorPageState extends ConsumerState<ThemeEditorPage> {
  late final ThemeDraft _draft = ThemeDraft(
    widget.seed ?? ThemeEditorSeed.fromBase('dark'),
  );
  late final _name = TextEditingController(text: _draft.document.name);
  final _contrastKey = GlobalKey();
  final _pickerKey = GlobalKey();
  final _scroll = ScrollController();
  _OpenPicker? _open;
  String? _error;
  String? _notice;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SettingsSubPages.of(
      context,
    ).setGuard(_DiscardGuard(_draft, _confirmDiscard));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _name.dispose();
    _draft.dispose();
    super.dispose();
  }

  /// Shows [error] or [notice] at the top, scrolling back to it.
  void _say({String? error, String? notice}) {
    setState(() {
      _error = error;
      _notice = notice;
    });
    if (error == null && notice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          0,
          duration: AppMotion.reduced(context, AppMotion.base),
          curve: AppMotion.entrance,
        ),
      );
    });
  }

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final failure = await runGuarded(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) _say(error: failure);
  }

  bool _requireValid() {
    if (_draft.canSave) return true;
    _say(
      error: _draft.nameValid
          ? 'Fix the failing contrast checks first.'
          : 'Give the theme a name of 1 to $themeNameMaxChars characters.',
    );
    return false;
  }

  Future<bool> _persist() async {
    if (!_requireValid()) return false;
    final before = _draft.savedText;
    final id = await ref
        .read(myThemesProvider.notifier)
        .save(_draft.document, id: _draft.mineId);
    if (id == null) {
      _say(error: 'This device holds $myThemesMax themes. Delete one first.');
      return false;
    }
    final applied = ref.read(customThemeProvider);
    if (applied != null && applied.toJsonText() == before) {
      await ref.read(customThemeProvider.notifier).set(_draft.document);
      await ref
          .read(customThemeSourceProvider.notifier)
          .set(MineThemeSource(id));
    }
    _draft.markSaved(id);
    return true;
  }

  Future<void> _save() async {
    _closePicker();
    if (await _persist() && mounted) _say(notice: 'Saved to Mine.');
  }

  Future<void> _saveAndApply() async {
    _closePicker();
    if (!await _persist() || !mounted) return;
    await applyThemeDocument(
      ref,
      _draft.document,
      source: MineThemeSource(_draft.mineId!),
    );
    if (mounted) _say(notice: 'Saved to Mine and applied.');
  }

  Future<void> _publish() async {
    if (!_requireValid()) return;
    await _run('publish the theme', () async {
      await publishTheme(ref, _draft.document);
      _say(notice: 'Published to the Space.');
    });
  }

  Future<void> _export() async {
    if (!_requireValid()) return;
    final bytes = utf8.encode(_draft.document.toJsonText());
    final name = themeFileName(_draft.document.name);
    try {
      final saved = await ref.read(themeFileSaverProvider)(name, bytes);
      if (saved && mounted) _say(notice: 'Exported $name.');
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.platform,
        'save the theme file',
        error,
        stack,
      );
      _say(error: 'Could not save the file.');
    }
  }

  Future<void> _delete() async {
    final id = _draft.mineId;
    if (id == null) return;
    final sure = await confirmDangerousAction(
      context,
      title: 'Delete ${_draft.document.name.trim()}?',
      message: 'This device holds the only copy.',
      confirmLabel: 'Delete',
    );
    if (!sure || !mounted) return;
    await ref.read(myThemesProvider.notifier).remove(id);
    if (!mounted) return;
    final stack = SettingsSubPages.of(context)..setGuard(null);
    await stack.pop();
  }

  Future<bool> _confirmDiscard() => confirmChoice(
    context,
    title: 'Discard your changes?',
    message: 'What you changed since the last save is lost.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep editing',
    confirmVariant: AppButtonVariant.danger,
    confirmKey: const Key('theme-editor-confirm'),
  );

  /// Opens [token]'s picker, inline where there is room and as a sheet below.
  Future<void> _tapColour(String token, _Place place, {required bool roomy}) {
    if (!roomy) return showThemeColourSheet(context, _draft, token);
    final open = _open;
    setState(() {
      _open = open?.token == token && open?.place == place
          ? null
          : (
              token: token,
              place: place,
              mark: _draft.mark(),
              note: themeLinkNote(_draft.links, token),
            );
    });
    if (_open != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(_pickerKey));
    }
    return Future.value();
  }

  /// Closes an inline picker, keeping its colour unless [revert].
  void _closePicker({bool revert = false}) {
    final open = _open;
    if (open == null) return;
    if (revert) _draft.restore(open.mark);
    setState(() => _open = null);
  }

  void _fix(VoidCallback fix) {
    _closePicker();
    fix();
  }

  /// Scrolls [key]'s card into view; [atEnd] scrolls only until its end shows.
  void _reveal(GlobalKey key, {bool atEnd = true}) {
    final target = key.currentContext;
    if (target == null || !mounted) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        duration: AppMotion.reduced(context, AppMotion.base),
        curve: AppMotion.entrance,
        alignmentPolicy: atEnd
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.explicit,
      ),
    );
  }

  Widget _picker(String token) => ThemeColourPanel(
    key: _pickerKey,
    draft: _draft,
    token: token,
    note: _open?.note,
    onDone: _closePicker,
    onCancel: () => _closePicker(revert: true),
  );

  String? _openIn(_Place place) => _open?.place == place ? _open?.token : null;

  List<Widget> _cards({required bool roomy}) {
    final failing = _draft.failingColours;
    return [
      ThemeEditorDetails(draft: _draft, name: _name, onStartFrom: _closePicker),
      ThemeMainColours(
        colours: _draft.document.colours,
        links: _draft.links,
        failing: failing,
        openToken: _openIn(_Place.main),
        onTap: (t) => unawaited(_tapColour(t, _Place.main, roomy: roomy)),
        picker: _picker,
      ),
      KeyedSubtree(
        key: _contrastKey,
        child: ThemeContrastPanel(
          checks: _draft.checks,
          colours: _draft.document.colours,
          onFixColour: (t) => _fix(() => _draft.fixColour(t)),
          onFixAll: () => _fix(_draft.applyAllFixes),
        ),
      ),
      if (roomy)
        ThemeTokenGrid(
          colours: _draft.document.colours,
          links: _draft.links,
          failing: failing,
          openToken: _openIn(_Place.grid),
          onTap: (t) => unawaited(_tapColour(t, _Place.grid, roomy: true)),
          picker: _picker,
        )
      else
        ThemeTokenGroupsCompact(
          draft: _draft,
          onTap: (t) => unawaited(_tapColour(t, _Place.grid, roomy: false)),
        ),
    ];
  }

  List<Widget> _messages(double inset) => [
    if (_error != null)
      Padding(
        padding: EdgeInsets.fromLTRB(inset, AppSpacing.s12, inset, 0),
        child: AppErrorState(
          key: const Key('theme-editor-error'),
          message: _error!,
          onDismiss: () => setState(() => _error = null),
        ),
      ),
    if (_notice != null)
      SettingsInfoLine(
        _notice!,
        key: const Key('theme-editor-notice'),
        padding: EdgeInsets.fromLTRB(inset, AppSpacing.s12, inset, 0),
      ),
  ];

  Widget _preview({required double inset, required bool roomy}) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final wide = inset > AppSpacing.s16;
    final vertical = wide ? AppSpacing.s16 : AppSpacing.s12;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, vertical, inset, vertical),
        child: AppContentColumn(
          child: ThemeMiniature.forDocument(
            _draft.document,
            key: const Key('theme-editor-preview'),
            detail: roomy
                ? ThemeMiniatureDetail.draft
                : ThemeMiniatureDetail.draftStrip,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _draft,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final wide = MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;
        final inset = wide ? AppSpacing.s32 : AppSpacing.s16;
        final content = math.min(box.maxWidth - 2 * inset, kContentColumnMax);
        final roomy = content >= _roomyFrom;
        final pin =
            box.maxHeight >= MediaQuery.textScalerOf(context).scale(_pinFrom);
        final preview = _preview(inset: inset, roomy: roomy);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThemeEditorHeader(
              draft: _draft,
              busy: _busy,
              onAction: (a) => unawaited(switch (a) {
                ThemeEditorAction.publish => _publish(),
                ThemeEditorAction.export => _export(),
                ThemeEditorAction.delete => _delete(),
              }),
            ),
            Expanded(
              child: CustomScrollView(
                key: const Key('theme-editor-tokens'),
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _messages(inset),
                    ),
                  ),
                  if (pin)
                    PinnedHeaderSliver(child: preview)
                  else
                    SliverToBoxAdapter(child: preview),
                  // Not lazy: the footer scrolls to Contrast, which must be built to be found.
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      AppSpacing.s24,
                      inset,
                      AppSpacing.s24,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: AppContentColumn(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _cards(roomy: roomy),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ThemeEditorFooter(
              failingChecks: _draft.failing.length,
              nameValid: _draft.nameValid,
              busy: _busy,
              compact: !roomy,
              inset: inset,
              onSave: () => unawaited(_save()),
              onSaveAndApply: () => unawaited(_saveAndApply()),
              onFixAll: () => _fix(_draft.applyAllFixes),
              onShowContrast: () => _reveal(_contrastKey, atEnd: false),
            ),
          ],
        );
      },
    ),
  );
}

/// Asks before an edited theme is left; the stack listens through the draft.
class _DiscardGuard implements SettingsLeaveGuard, Listenable {
  _DiscardGuard(this._draft, this._confirm);

  final ThemeDraft _draft;
  final Future<bool> Function() _confirm;

  @override
  bool get blocking => _draft.dirty;

  @override
  Future<bool> confirmLeave() => _confirm();

  @override
  void addListener(VoidCallback listener) => _draft.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _draft.removeListener(listener);
}
