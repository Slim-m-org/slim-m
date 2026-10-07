// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unit tests for `gifs.rs` itself - construction, error mapping, and the
//! filename extension helper. The token cache has its own tests beside it in
//! `cache.rs`. The full search-pick-select round trip against a fake
//! provider lives in `tests/gif_picker.rs` instead, since that needs a real
//! router and a real fake HTTP server neither of which belongs in a unit test.

use super::*;

#[test]
fn gif_error_maps_to_the_documented_status_codes() {
    assert!(matches!(
        ApiError::from(GifError::NotConfigured),
        ApiError::NotConfigured(_)
    ));
    assert!(matches!(
        ApiError::from(GifError::Unavailable),
        ApiError::Unavailable
    ));
    // Not Unavailable: only a fresh search fixes a stale token, never a retry.
    assert!(matches!(
        ApiError::from(GifError::StaleToken),
        ApiError::NotFound(_)
    ));
}

#[test]
fn extension_matches_the_two_sniffable_gif_content_types() {
    assert_eq!(extension_for("image/gif"), "gif");
    assert_eq!(extension_for("image/webp"), "webp");
}

#[test]
fn new_stays_disabled_when_neither_setting_is_present() {
    let gifs = GifSearch::new(&Config::default()).expect("no provider is not an error");
    assert!(!gifs.is_enabled());
}

/// Only one of the pair being set is the same as neither: a self-host that
/// half-configures this by accident gets no GIF search rather than a
/// confusing runtime failure the first time it is used.
#[test]
fn new_stays_disabled_with_only_a_provider_or_only_a_key() {
    let only_provider = GifSearch::new(&Config {
        gif_provider: Some("tenor".to_owned()),
        ..Config::default()
    })
    .expect("half-configured is not an error");
    assert!(!only_provider.is_enabled());

    let only_key = GifSearch::new(&Config {
        gif_api_key: Some("k".to_owned()),
        ..Config::default()
    })
    .expect("half-configured is not an error");
    assert!(!only_key.is_enabled());
}

#[test]
fn new_fails_at_startup_on_an_unrecognized_provider_name() {
    let result = GifSearch::new(&Config {
        gif_provider: Some("giphy".to_owned()),
        gif_api_key: Some("k".to_owned()),
        ..Config::default()
    });
    assert!(result.is_err());
}

/// Reproduces the real failure this once shipped as: `docker-compose.yml`
/// wires `SLIMM_GIF_PROVIDER: ${SLIMM_GIF_PROVIDER:-}`, so an operator who
/// never set it gets an empty string in the container's environment, not an
/// absent variable - `Config::gif_provider` deserializes that as
/// `Some(String::new())`, never `None`. Before this was fixed the server
/// crashed at startup with `SLIMM_GIF_PROVIDER must be "tenor" or "klipy",
/// got ""` on every deployment that had never touched this setting at all.
#[test]
fn new_stays_disabled_when_both_settings_are_the_empty_string() {
    let gifs = GifSearch::new(&Config {
        gif_provider: Some(String::new()),
        gif_api_key: Some(String::new()),
        ..Config::default()
    })
    .expect("an empty string reads the same as unset, not a bad provider name");
    assert!(!gifs.is_enabled());
}

/// The same empty-reads-as-unset rule applies per field, not only when both
/// are empty together - a key set beside an empty provider name must not
/// try to parse `""` as a provider.
#[test]
fn new_stays_disabled_when_only_one_setting_is_the_empty_string() {
    let empty_provider = GifSearch::new(&Config {
        gif_provider: Some(String::new()),
        gif_api_key: Some("k".to_owned()),
        ..Config::default()
    })
    .expect("an empty provider name is unset, not invalid");
    assert!(!empty_provider.is_enabled());

    let empty_key = GifSearch::new(&Config {
        gif_provider: Some("tenor".to_owned()),
        gif_api_key: Some(String::new()),
        ..Config::default()
    })
    .expect("an empty api key is unset, not invalid");
    assert!(!empty_key.is_enabled());
}

#[test]
fn new_is_case_insensitive_and_enables_on_either_recognized_name() {
    for name in ["tenor", "TENOR", "Klipy"] {
        let gifs = GifSearch::new(&Config {
            gif_provider: Some(name.to_owned()),
            gif_api_key: Some("k".to_owned()),
            ..Config::default()
        })
        .unwrap_or_else(|_| panic!("{name} is a recognized provider"));
        assert!(gifs.is_enabled());
    }
}

#[test]
fn slug_filename_makes_a_useful_name_from_a_title() {
    assert_eq!(
        slug_filename("When You Realize Tomorrow is Friday Meme"),
        "when_you_realize_tomorrow_is_friday_meme"
    );
    // Punctuation and runs of separators collapse to one underscore.
    assert_eq!(slug_filename("Dat Boi  --  o'RLY?!"), "dat_boi_o_rly");
    // Leading/trailing separators never become edge underscores.
    assert_eq!(slug_filename("  hello  "), "hello");
}

#[test]
fn slug_filename_falls_back_when_there_is_nothing_usable() {
    assert_eq!(slug_filename(""), "gif");
    assert_eq!(slug_filename("!!! ???"), "gif");
}

#[test]
fn slug_filename_caps_a_verbose_title() {
    let long = "a".repeat(200);
    assert!(slug_filename(&long).len() <= filename::GIF_SLUG_MAX_CHARS);
}

#[test]
fn slug_filename_caps_word_separated_titles() {
    let title = format!("{} b", "a".repeat(47));
    let slug = slug_filename(&title);
    assert!(
        slug.len() <= filename::GIF_SLUG_MAX_CHARS,
        "len {}",
        slug.len()
    );
}
