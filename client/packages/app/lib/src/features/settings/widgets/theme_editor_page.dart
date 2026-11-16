// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor (decision 0106), a page above Themes in the Appearance
/// pane: a colour picker per token, a live preview and the contrast floors,
/// side by side on a wide window and stacked on a phone.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/my_themes.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_file_io.dart';
import '../providers/theme_source.dart';
import '../providers/theme_store.dart';
import '../providers/theme_store_actions.dart';
import '../providers/stored_theme.dart';
import 'settings_field.dart';
import 'settings_info_line.dart';
import 'settings_pane_body.dart' show kSettingsWidePaneInset;
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_segmented_row.dart';
import 'settings_sub_pages.dart';
import 'theme_contrast_panel.dart';
import 'theme_editor_menu.dart';
import 'theme_editor_preview.dart';
import 'theme_menu_button.dart';
import 'theme_token_group.dart';

/// Wide enough for the tokens and the preview to sit side by side.
const _sideBySideWidth = 640.0;

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

class _ThemeEditorPageState extends ConsumerState<ThemeEditorPage> {
  late final ThemeDraft _draft = ThemeDraft(
    widget.seed ?? ThemeEditorSeed.fromBase('dark'),
  );
  late final _name = TextEditingController(text: _draft.document.name);

  @override
  void initState() {
    super.initState();
    SettingsSubPages.of(
      context,
    ).setGuard(_DiscardGuard(_draft, _confirmDiscard));
  }

  String? _openToken;
  Color? _openInitial;
  String? _error;
  String? _notice;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _draft.dispose();
    super.dispose();
  }

  void _say({String? error, String? notice}) => setState(() {
    _error = error;
    _notice = notice;
  });

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
    if (await _persist() && mounted) _say(notice: 'Saved to Mine.');
  }

  Future<void> _apply() async {
    if (!await _persist() || !mounted) return;
    await applyThemeDocument(
      ref,
      _draft.document,
      source: MineThemeSource(_draft.mineId!),
    );
    if (mounted) _say(notice: 'Applied.');
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
    final sure = await confirmThemeEditorSheet(
      context,
      title: 'Delete this theme?',
      action: 'Delete',
    );
    if (sure != true || !mounted) return;
    await ref.read(myThemesProvider.notifier).remove(id);
    if (!mounted) return;
    final stack = SettingsSubPages.of(context)..setGuard(null);
    await stack.pop();
  }

  Future<bool> _confirmDiscard() async =>
      await confirmThemeEditorSheet(
        context,
        title: 'Discard your changes?',
        action: 'Discard',
      ) ==
      true;

  Future<void> _leave() => SettingsSubPages.of(context).pop();

  Future<void> _tapToken(String token, {required bool inline}) async {
    final before = _draft.document.colours[token]!;
    if (inline) {
      setState(() {
        _openToken = _openToken == token ? null : token;
        _openInitial = before;
      });
      return;
    }
    final picked = await showAppColourPicker(
      context,
      initial: before.withValues(alpha: 1),
      title: themeTokenLabels[token]!,
      onChanged: (c) => _draft.setColour(token, c),
    );
    _draft.setColour(token, picked ?? before);
  }

  void _closePicker({required bool revert}) {
    final token = _openToken;
    if (token != null && revert) _draft.setColour(token, _openInitial!);
    setState(() => _openToken = null);
  }

  Widget _details() {
    final doc = _draft.document;
    return SettingsSectionCard(
      title: 'Details',
      topGap: 0,
      children: [
        SettingsCardBlock(
          children: [
            SettingsField(
              label: 'Name',
              child: AppInput(
                key: const Key('theme-editor-name'),
                controller: _name,
                semanticLabel: 'Theme name',
                counterMax: themeNameMaxChars,
                errorText: _draft.nameValid
                    ? null
                    : 'Use 1 to $themeNameMaxChars characters.',
                onChanged: _draft.setName,
              ),
            ),
          ],
        ),
        SettingsSegmentedRow<Brightness>(
          label: 'Mode',
          value: doc.brightness,
          choices: const [
            SettingsChoice(value: Brightness.dark, label: 'Dark'),
            SettingsChoice(value: Brightness.light, label: 'Light'),
          ],
          onChanged: _draft.setBrightness,
        ),
        _startFrom(),
      ],
    );
  }

  Widget _startFrom() {
    final mine = ref.watch(myThemesProvider);
    final space =
        ref.watch(spaceThemesProvider).valueOrNull?.themes ?? const [];
    final sources = themeEditorSources(mine: mine, space: space);
    return SettingsSelectRow<String>(
      key: const Key('theme-editor-start-from'),
      label: 'Start from',
      description: 'Keeps your name.',
      value: null,
      unknownLabel: 'Choose a theme',
      choices: [
        for (final s in sources) SettingsChoice(value: s.key, label: s.label),
      ],
      onChanged: (key) {
        final source = sources.firstWhere((s) => s.key == key);
        _closePicker(revert: false);
        _draft.startFrom(source.document);
      },
    );
  }

  Widget _tokens({required bool inline}) {
    final failing = {
      for (final c in _draft.failing) ...[c.fg, if (!c.quieter) c.bg],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in themeTokenGroups)
          ThemeTokenGroupCard(
            group: group,
            colours: _draft.document.colours,
            failing: failing,
            openToken: inline ? _openToken : null,
            onTap: (t) => unawaited(_tapToken(t, inline: inline)),
            onPreview: _draft.setColour,
            onSave: (t, c) {
              _draft.setColour(t, c);
              _closePicker(revert: false);
            },
            onCancel: (_) => _closePicker(revert: true),
            onOpacity: _draft.setOpacity,
          ),
      ],
    );
  }

  Widget _contrast() => ThemeContrastPanel(
    checks: _draft.checks,
    colours: _draft.document.colours,
    onFix: _draft.applyFix,
    onFixAll: _draft.applyAllFixes,
  );

  List<Widget> _messages() => [
    if (_error != null)
      Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s8),
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
        padding: const EdgeInsets.only(top: AppSpacing.s8),
      ),
  ];

  List<Widget> _actions() => [
    AppButton(
      key: const Key('theme-editor-save'),
      label: 'Save',
      variant: AppButtonVariant.primary,
      size: AppButtonSize.sm,
      disabled: _busy || !_draft.canSave,
      onPressed: () => unawaited(_save()),
    ),
    ThemeMenuButton<ThemeEditorAction>(
      key: const Key('theme-editor-menu'),
      semanticLabel: 'More for this theme',
      enabled: !_busy,
      onSelected: (a) => unawaited(switch (a) {
        ThemeEditorAction.apply => _apply(),
        ThemeEditorAction.publish => _publish(),
        ThemeEditorAction.export => _export(),
        ThemeEditorAction.delete => _delete(),
      }),
      items: (pick) =>
          themeEditorMenuItems(pick, canDelete: _draft.mineId != null),
    ),
    const SizedBox(width: AppSpacing.s8),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _draft,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;
      final header = SettingsSubPageHeader(
        title: _draft.mineId == null ? 'New theme' : 'Edit theme',
        backLabel: 'Back to Themes',
        onBack: () => unawaited(_leave()),
        actions: _actions(),
        onClose: SettingsSubPages.closeOf(context),
      );
      final body = LayoutBuilder(
        builder: (context, box) =>
            box.maxWidth >= _sideBySideWidth ? _sideBySide() : _stacked(),
      );
      final inset = wide
          ? kSettingsWidePaneInset
          : const EdgeInsets.all(AppSpacing.s16);
      final padding = EdgeInsets.fromLTRB(
        inset.left,
        inset.top,
        inset.right,
        SettingsSubPages.bottomInsetOf(context),
      );
      if (!wide) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: AppContentColumn(
                child: Padding(padding: padding, child: body),
              ),
            ),
          ],
        );
      }
      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AppSpacing.s16,
          children: [
            header,
            Expanded(child: body),
          ],
        ),
      );
    },
  );

  Widget _sideBySide() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 5,
        child: ListView(
          key: const Key('theme-editor-tokens'),
          children: [..._messages(), _details(), _tokens(inline: true)],
        ),
      ),
      Expanded(
        flex: 4,
        child: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ThemeEditorPreview(document: _draft.document),
              Expanded(child: ListView(children: [_contrast()])),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _stacked() => Column(
    children: [
      ThemeEditorPreview(document: _draft.document, compact: true),
      const SizedBox(height: AppSpacing.s8),
      Expanded(
        child: ListView(
          key: const Key('theme-editor-tokens'),
          children: [
            ..._messages(),
            _details(),
            _contrast(),
            _tokens(inline: false),
          ],
        ),
      ),
    ],
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
