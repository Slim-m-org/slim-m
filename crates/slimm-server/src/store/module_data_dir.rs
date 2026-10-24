// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Where each module's data file lives (decision 0091, `data.store`).

use std::path::PathBuf;
use std::sync::Arc;

use super::Store;

impl Store {
    /// The same store keeping module data files in `dir`.
    pub fn with_modules_dir(mut self, dir: PathBuf) -> Self {
        self.modules_dir = Some(Arc::new(dir));
        self
    }

    /// The configured modules directory, or a `modules` directory beside the database file.
    pub fn modules_dir(&self) -> PathBuf {
        if let Some(dir) = &self.modules_dir {
            return dir.as_ref().clone();
        }
        let database = self.pool.connect_options().get_filename().to_path_buf();
        database
            .parent()
            .map_or_else(|| PathBuf::from("modules"), |p| p.join("modules"))
    }
}
