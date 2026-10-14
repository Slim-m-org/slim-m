// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The music that plays while you are alone in a call: one bundled CC0 track
/// per style. Credits and sources are in `assets/audio/music/CREDITS.md`.
library;

enum LoungeTrack {
  lofi('Lofi', 'Chill lofi inspired', 'lofi.mp3'),
  jazz('Jazz', 'Elevator Music', 'jazz.mp3'),
  electronic('Electronic', 'Hypnotic Chill', 'electronic.mp3'),
  ambient('Ambient', 'Contemplation', 'ambient.mp3');

  const LoungeTrack(this.style, this.title, this._file);

  /// What the picker calls it.
  final String style;

  /// The track's own name, shown under the style.
  final String title;
  final String _file;

  /// The asset path `AssetSource` takes, which is relative to `assets/`.
  String get asset => 'audio/music/$_file';

  /// The one after this, wrapping round, for "Next track".
  LoungeTrack get next => values[(index + 1) % values.length];

  /// The stored [name], or the default for anything unknown.
  static LoungeTrack fromName(String? name) =>
      values.where((t) => t.name == name).firstOrNull ?? LoungeTrack.lofi;
}
