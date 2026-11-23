// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Connectors (decision 0090): a module whose logic is an external program
//! holding a bot token scoped to what the admin approved at install.

mod fake_supervisor;
mod harness;
mod host_run;
mod host_run_monitor;
mod host_run_runs;
mod host_run_world;
mod install;
mod runs;
mod runs_world;
mod scope;
mod settings;
