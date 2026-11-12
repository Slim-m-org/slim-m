// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the bulk emoji import.
//!
//! Split by what a file's fate is rather than by which function decides it:
//! [`importing`] covers a file becoming an emoji, [`refusals`] a file the
//! report has to explain, and [`limits`] the two ceilings. [`fixtures`] is the
//! temp database, temp directories and magic-number images they share.

mod fixtures;
mod importing;
mod limits;
mod refusals;

use crate::support;
