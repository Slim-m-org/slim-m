// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

/// `Default` reuses the same `default_*` functions serde calls when a
/// field is missing from the environment, but nothing stops the two from
/// drifting apart if a future edit changes one and not the other. This
/// deserializes an empty environment map through the same `Deserialize`
/// impl `from_env` uses and checks it lands on exactly what `Default`
/// produces, so that drift fails a test instead of shipping silently.
#[test]
fn default_matches_deserializing_an_empty_config() {
    let empty: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let from_empty_env: Config = envy::from_iter(empty).expect("all fields have defaults");
    let defaulted = Config::default();

    assert_eq!(from_empty_env.port, defaulted.port);
    assert_eq!(from_empty_env.database_path, defaulted.database_path);
    assert_eq!(from_empty_env.hash_concurrency, defaulted.hash_concurrency);
    assert_eq!(from_empty_env.push_relay_url, defaulted.push_relay_url);
    assert_eq!(from_empty_env.push_relay_key, defaulted.push_relay_key);
    assert_eq!(from_empty_env.livekit_url, defaulted.livekit_url);
    assert_eq!(from_empty_env.livekit_api_key, defaulted.livekit_api_key);
    assert_eq!(
        from_empty_env.livekit_api_secret,
        defaulted.livekit_api_secret
    );
    assert_eq!(from_empty_env.attachments_dir, defaulted.attachments_dir);
    assert_eq!(
        from_empty_env.attachment_max_bytes,
        defaulted.attachment_max_bytes
    );
    assert_eq!(from_empty_env.gif_provider, defaulted.gif_provider);
    assert_eq!(from_empty_env.gif_api_key, defaulted.gif_api_key);
    assert_eq!(
        from_empty_env.cors_allowed_origins,
        defaulted.cors_allowed_origins
    );
    assert_eq!(from_empty_env.addons_repo, defaulted.addons_repo);
    assert_eq!(from_empty_env.code_runner_url, defaulted.code_runner_url);
}

/// The shipped `docker-compose.yml` writes
/// `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES: ${VAR:-}`, which is an empty string
/// rather than an absent variable. That used to reach `u64`'s parser and
/// kill the process on boot with "cannot parse integer from empty
/// string", so the self-host example could not start unless the operator
/// happened to set a ceiling. Blank means no ceiling.
#[test]
fn a_blank_attachment_ceiling_means_no_ceiling_rather_than_a_boot_failure() {
    let env =
        std::collections::HashMap::from([("MAX_TOTAL_ATTACHMENT_BYTES".to_owned(), String::new())]);
    let config: Config = envy::from_iter(env).expect("a blank ceiling must not fail to parse");
    assert_eq!(config.max_total_attachment_bytes, None);
}

/// A compose file's `${VAR:-}` hands a blank sidecar URL through, which must mean off.
#[test]
fn blank_sidecar_urls_read_as_unset_and_real_ones_survive() {
    let env = std::collections::HashMap::from([
        ("PUSH_RELAY_URL".to_owned(), String::new()),
        ("CODE_RUNNER_URL".to_owned(), "  ".to_owned()),
    ]);
    let config: Config = envy::from_iter(env).expect("blank sidecar URLs parse");
    assert_eq!(config.push_relay_url, None);
    assert_eq!(config.code_runner_url, None);

    let env = std::collections::HashMap::from([(
        "CODE_RUNNER_URL".to_owned(),
        "http://piston:2000".to_owned(),
    )]);
    let config: Config = envy::from_iter(env).expect("a real URL parses");
    assert_eq!(
        config.code_runner_url.as_deref(),
        Some("http://piston:2000")
    );
}

/// The blank-is-none reading must not have swallowed real values.
#[test]
fn a_real_attachment_ceiling_is_still_read() {
    let env = std::collections::HashMap::from([(
        "MAX_TOTAL_ATTACHMENT_BYTES".to_owned(),
        "1048576".to_owned(),
    )]);
    let config: Config = envy::from_iter(env).expect("a real ceiling parses");
    assert_eq!(config.max_total_attachment_bytes, Some(1_048_576));
}

/// A value that is not a number is still an operator error worth failing on.
#[test]
fn a_nonsense_attachment_ceiling_still_fails() {
    let env = std::collections::HashMap::from([(
        "MAX_TOTAL_ATTACHMENT_BYTES".to_owned(),
        "lots".to_owned(),
    )]);
    assert!(envy::from_iter::<_, Config>(env).is_err());
}

#[test]
fn the_default_addons_repo_is_the_org_one_with_the_old_slug_behind_it() {
    assert_eq!(
        Config::default().addons_repos(),
        vec!["Slim-m-org/slim-addons", "NC1107/slim-addons"]
    );
}

#[test]
fn a_pinned_legacy_addons_repo_falls_back_to_the_org_one() {
    let env = std::collections::HashMap::from([(
        "ADDONS_REPO".to_owned(),
        "nc1107/slim-addons".to_owned(),
    )]);
    let config: Config = envy::from_iter(env).expect("a slug parses");
    assert_eq!(
        config.addons_repos(),
        vec!["nc1107/slim-addons", "Slim-m-org/slim-addons"]
    );
}

#[test]
fn an_operators_own_addons_repo_has_no_fallback() {
    let env = std::collections::HashMap::from([(
        "ADDONS_REPO".to_owned(),
        "someone/their-addons".to_owned(),
    )]);
    let config: Config = envy::from_iter(env).expect("a slug parses");
    assert_eq!(config.addons_repos(), vec!["someone/their-addons"]);
}

/// An unset origin list and an explicitly empty one must be the same
/// thing, because `SLIMM_CORS_ALLOWED_ORIGINS=` in a compose file is how
/// an operator turns the browser surface back off.
#[test]
fn an_empty_origin_list_is_read_as_an_empty_string_not_dropped() {
    let env = std::collections::HashMap::from([("CORS_ALLOWED_ORIGINS".to_owned(), String::new())]);
    let config: Config = envy::from_iter(env).expect("all other fields have defaults");
    assert_eq!(config.cors_allowed_origins.as_deref(), Some(""));
}
