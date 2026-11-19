// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::files::tests::ScratchDir;
use super::*;

fn settings(dir: &Path, base: &str) -> LogSettings {
    LogSettings {
        base_filter: base.to_owned(),
        dir: Some(dir.to_owned()),
        limits: FileLimits::new(14, 1 << 24),
    }
}

fn written(logging: &Logging) -> String {
    logging.flush();
    let plan = plan_recent(logging.dir().unwrap(), 1 << 24, today()).unwrap();
    String::from_utf8(read_plan(&plan).unwrap()).unwrap()
}

fn emit_each_kind() {
    tracing::info!(target: "slimm_server::store", "an info line");
    tracing::debug!(target: "slimm_server::http::ws", "a socket debug line");
    tracing::debug!(target: "slimm_server::store", "a store debug line");
    tracing::trace!(target: "slimm_server::voice", "a voice trace line");
    tracing::debug!(target: "sqlx::query", "a dependency debug line");
}

#[test]
fn each_mode_lets_through_its_own_lines_and_switches_without_a_rebuild() {
    let dir = ScratchDir::new("log-modes");
    let built = Logging::build(&settings(&dir.0, ""), false);
    let logging = built.logging;
    let seen = |mode: LogMode| {
        // A reload rebuilds interest against the thread's dispatcher, which in production is the global one.
        tracing::dispatcher::with_default(&built.dispatch, || logging.set_mode(mode));
        let before = written(&logging).len();
        tracing::dispatcher::with_default(&built.dispatch, emit_each_kind);
        written(&logging)[before..].to_owned()
    };

    let off = seen(LogMode::Off);
    assert!(off.contains("an info line"), "{off}");
    assert!(
        !off.contains("debug line") && !off.contains("trace line"),
        "{off}"
    );

    let compact = seen(LogMode::Compact);
    assert!(compact.contains("a socket debug line"), "{compact}");
    assert!(!compact.contains("a store debug line"), "{compact}");
    assert!(!compact.contains("trace line"), "{compact}");

    let verbose = seen(LogMode::Verbose);
    assert!(verbose.contains("a store debug line"), "{verbose}");
    assert!(verbose.contains("a voice trace line"), "{verbose}");
    assert!(
        verbose.contains("logging/tests.rs"),
        "Verbose names the source: {verbose}"
    );
    assert!(!verbose.contains("a dependency debug line"), "{verbose}");

    let back = seen(LogMode::Off);
    assert!(!back.contains("debug line"), "{back}");
    assert_eq!(logging.mode(), LogMode::Off);
}

#[test]
fn the_operators_filter_is_the_floor_every_mode_builds_on() {
    let dir = ScratchDir::new("log-base");
    let built = Logging::build(&settings(&dir.0, "warn,sqlx=debug"), false);
    tracing::dispatcher::with_default(&built.dispatch, || {
        built.logging.set_mode(LogMode::Compact);
    });
    tracing::dispatcher::with_default(&built.dispatch, emit_each_kind);
    let text = written(&built.logging);
    assert!(!text.contains("an info line"), "{text}");
    assert!(text.contains("a dependency debug line"), "{text}");
    assert!(text.contains("a socket debug line"), "{text}");
}

#[test]
fn a_nonsense_operator_filter_falls_back_to_info() {
    assert_eq!(valid_base("slimm_server=loud"), "info");
    assert_eq!(valid_base(" "), "info");
    assert_eq!(valid_base("debug"), "debug");
}

#[test]
fn lines_from_before_a_restart_are_still_there_after_it() {
    let dir = ScratchDir::new("log-reboot");
    let first = Logging::build(&settings(&dir.0, ""), false);
    tracing::dispatcher::with_default(&first.dispatch, || {
        tracing::info!(target: "slimm_server", "the call dropped here");
    });
    first.logging.flush();
    drop(first);

    let second = Logging::build(&settings(&dir.0, ""), false);
    tracing::dispatcher::with_default(&second.dispatch, || {
        tracing::info!(target: "slimm_server", "started again");
    });
    let text = written(&second.logging);
    let dropped = text
        .find("the call dropped here")
        .expect("kept across the restart");
    assert!(dropped < text.find("started again").unwrap(), "{text}");
}

#[test]
fn a_noisy_debug_call_site_is_capped_but_warnings_never_are() {
    let dir = ScratchDir::new("log-throttle");
    let built = Logging::build(&settings(&dir.0, ""), false);
    tracing::dispatcher::with_default(&built.dispatch, || {
        built.logging.set_mode(LogMode::Verbose);
        for i in 0..500 {
            tracing::debug!(target: "slimm_server::hub", i, "noisy");
        }
        for i in 0..100 {
            tracing::warn!(target: "slimm_server::hub", i, "loud");
        }
    });
    let text = written(&built.logging);
    let noisy = text.matches("noisy").count();
    assert!(
        noisy <= DEBUG_LINES_PER_SECOND as usize * 2,
        "{noisy} noisy lines"
    );
    assert!(
        noisy >= DEBUG_LINES_PER_SECOND as usize,
        "{noisy} noisy lines"
    );
    assert_eq!(text.matches("loud").count(), 100);
    assert!(built.logging.throttled.load(Ordering::Relaxed) > 0);
}

#[test]
fn files_are_skipped_when_the_size_budget_is_zero() {
    let config = Config {
        log_max_bytes: 0,
        ..Config::default()
    };
    assert_eq!(LogSettings::from_config(&config).dir, None);
    let config = Config {
        database_path: "/data/slimm.db".to_owned(),
        ..Config::default()
    };
    assert_eq!(
        LogSettings::from_config(&config).dir,
        Some(PathBuf::from("/data/logs"))
    );
}

#[test]
fn every_mode_name_round_trips() {
    for mode in [LogMode::Off, LogMode::Compact, LogMode::Verbose] {
        assert_eq!(LogMode::parse(mode.as_str()), Some(mode));
        assert_eq!(LogMode::from_u8(mode.to_u8()), mode);
    }
    assert_eq!(LogMode::parse("loud"), None);
}

#[test]
fn the_files_never_carry_the_colour_codes_stdout_gets() {
    let dir = ScratchDir::new("log-plain");
    let built = Logging::build(&settings(&dir.0, ""), true);
    tracing::dispatcher::with_default(&built.dispatch, || {
        let span =
            tracing::info_span!(target: "slimm_server", "http_request", route = "/space/settings");
        let _entered = span.enter();
        tracing::info!(target: "slimm_server", "inside a request");
    });
    let text = written(&built.logging);
    assert!(text.contains("route=\"/space/settings\""), "{text}");
    assert!(!text.contains('\x1b'), "{text:?}");
}

#[test]
fn compact_never_throttles_its_one_line_per_request() {
    let dir = ScratchDir::new("log-compact-burst");
    let built = Logging::build(&settings(&dir.0, ""), false);
    tracing::dispatcher::with_default(&built.dispatch, || {
        built.logging.set_mode(LogMode::Compact);
        for i in 0..300 {
            tracing::debug!(target: "slimm_server::http::ws", i, "burst");
        }
    });
    assert_eq!(written(&built.logging).matches("burst").count(), 300);
}
