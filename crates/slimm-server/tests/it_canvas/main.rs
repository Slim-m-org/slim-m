// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the voice canvas: operations, writes, media slots and its sweeps: one module per former test file.

#[path = "../support/mod.rs"]
mod support;

mod canvas_batch;
mod canvas_cursor_live;
mod canvas_erased_reclaim;
mod canvas_fuzz;
mod canvas_gate_cost;
mod canvas_gate_midsession;
mod canvas_image;
mod canvas_index;
mod canvas_live;
mod canvas_media_slot_preview_live;
mod canvas_media_slots;
mod canvas_object_cap;
mod canvas_object_preview_live;
mod canvas_ops;
mod canvas_ops_rebuild;
mod canvas_ops_sweep;
mod canvas_ops_sweep_clear;
mod canvas_ops_sweep_replay;
mod canvas_perf;
mod canvas_screen_annotation_live;
mod canvas_spike;
mod canvas_state_version;
mod canvas_stroke_preview_live;
mod canvas_view_live;
mod canvas_viewport;
mod canvas_watch_live;
mod canvas_write;
mod canvas_write_hold;
mod scene_refresh;
mod scene_sweep_limits;
