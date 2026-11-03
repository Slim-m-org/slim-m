// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

/// A theme in the Space's store (decision 0106). [theme] is the document
/// without picture bytes; [hasPicture] says whether one can be fetched.
class SpaceTheme {
  const SpaceTheme({
    required this.id,
    required this.name,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    required this.hasPicture,
    required this.theme,
  });

  factory SpaceTheme.fromJson(Map<String, dynamic> json) => SpaceTheme(
        id: json['id'] as String,
        name: json['name'] as String,
        authorId: json['author_id'] as String?,
        authorName: json['author_name'] as String,
        createdAt: (json['created_at'] as num).toInt(),
        hasPicture: json['has_picture'] as bool,
        theme: Map<String, dynamic>.from(json['theme'] as Map),
      );

  final String id;
  final String name;

  /// Null once the author's account is deleted.
  final String? authorId;
  final String authorName;
  final int createdAt;
  final bool hasPicture;
  final Map<String, dynamic> theme;
}

class SpaceThemeList {
  const SpaceThemeList({required this.themes, this.defaultThemeId});

  factory SpaceThemeList.fromJson(Map<String, dynamic> json) => SpaceThemeList(
        themes: [
          for (final t in json['themes'] as List<dynamic>)
            SpaceTheme.fromJson(t as Map<String, dynamic>),
        ],
        defaultThemeId: json['default_theme_id'] as String?,
      );

  final List<SpaceTheme> themes;
  final String? defaultThemeId;
}
