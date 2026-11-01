// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The formula against the figures in perf/load/FINDINGS.md and docs/sizing.md.

use super::*;

const MIB: u64 = 1024 * 1024;

fn machine(cores: f64, mib: u64) -> Hardware {
    Hardware {
        cores,
        memory_bytes: mib * MIB,
    }
}

#[test]
fn the_planned_delivery_rate_stays_under_the_measured_clean_fanout_run() {
    // FINDINGS fanout: 252k deliveries a second, clean, at 2.9 cores average.
    let planned = DELIVERIES_PER_CORE * 2.9 * CPU_SAFETY;
    assert!(planned <= 0.51 * 252_000.0, "{planned}");
}

#[test]
fn requests_follow_the_measured_http_mix_steps() {
    // FINDINGS http_mix: last good step 2000, 2500, 3000 on 2, 4 and 8 CPUs.
    assert_eq!(http_requests_per_second(2.0), 2000.0);
    assert_eq!(http_requests_per_second(4.0), 2500.0);
    assert_eq!(http_requests_per_second(8.0), 3000.0);
    assert_eq!(http_requests_per_second(6.0), 2750.0);
}

#[test]
fn requests_do_not_grow_past_eight_cores() {
    // The 16 CPU row regressed before the SQLite flag; promising more would be a guess.
    assert_eq!(http_requests_per_second(16.0), 3000.0);
}

#[test]
fn requests_shrink_below_the_first_measured_step() {
    assert_eq!(http_requests_per_second(1.0), 1000.0);
    assert_eq!(http_requests_per_second(0.0), 0.0);
}

#[test]
fn memory_below_the_oom_ceiling_cannot_hold_what_the_server_accepted() {
    // docs/sizing.md: killed at 144 MB after accepting 879 to 976 connections.
    assert!(memory_connections(144 * MIB) < 879);
}

#[test]
fn memory_for_the_connection_cap_is_between_256_and_512_mib() {
    assert!(memory_connections(256 * MIB) < MAX_CONNECTIONS as u64);
    assert!(memory_connections(512 * MIB) >= MAX_CONNECTIONS as u64);
}

#[test]
fn no_memory_means_no_connections() {
    assert_eq!(memory_connections(0), 0);
    assert_eq!(memory_connections(RESERVE_BYTES), 0);
}

#[test]
fn a_big_machine_is_bound_by_the_connection_cap() {
    let estimate = estimate(machine(8.0, 16 * 1024), false);
    assert_eq!(estimate.binding, Binding::Connections);
    assert_eq!(estimate.connection_limit, 1024);
    assert_eq!((estimate.members_min, estimate.members_max), (340, 770));
}

#[test]
fn more_cores_past_four_buy_nothing() {
    let four = estimate(machine(4.0, 4096), false);
    let sixteen = estimate(machine(16.0, 4096), false);
    assert_eq!(four, sixteen);
}

#[test]
fn two_cores_are_bound_by_the_processor_just_under_the_cap() {
    let estimate = estimate(machine(2.0, 512), false);
    assert_eq!(estimate.binding, Binding::Processor);
    assert!((900..1024).contains(&estimate.connection_limit));
}

#[test]
fn one_core_carries_fewer_people_than_two() {
    let one = estimate(machine(1.0, 2048), false);
    let two = estimate(machine(2.0, 2048), false);
    assert!(one.members_max < two.members_max);
    assert_eq!(one.binding, Binding::Processor);
}

#[test]
fn small_memory_binds_before_the_processor() {
    let estimate = estimate(machine(4.0, 192), false);
    assert_eq!(estimate.binding, Binding::Memory);
    assert!(estimate.connection_limit < 1024);
}

#[test]
fn the_range_is_ordered_and_never_empty_on_a_real_machine() {
    for (cores, mib) in [(1.0, 256), (2.0, 512), (4.0, 8192), (8.0, 32768)] {
        let estimate = estimate(machine(cores, mib), true);
        assert!(estimate.members_min > 0, "{cores} cores {mib} MiB");
        assert!(estimate.members_min < estimate.members_max);
    }
}

#[test]
fn voice_is_absent_until_voice_is_configured() {
    let estimate = estimate(machine(4.0, 8192), false);
    assert_eq!((estimate.voice_min, estimate.voice_max), (None, None));
}

#[test]
fn voice_on_the_measured_512_mib_livekit_is_around_sixty() {
    // docs/sizing.md: sixty people comfortable on 512 MB, a hundred past the edge.
    let (low, high) = voice_range(512 * MIB, u32::MAX);
    assert!(low < 60 && (50..100).contains(&high), "{low} to {high}");
}

#[test]
fn voice_grows_with_memory_and_stays_under_the_member_range() {
    let small = estimate(machine(4.0, 2048), true);
    let large = estimate(machine(4.0, 16384), true);
    assert!(small.voice_max.unwrap() < large.voice_max.unwrap());
    assert!(large.voice_max.unwrap() <= large.members_max);
}
