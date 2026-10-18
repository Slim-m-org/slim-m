// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pictures of linked external accounts, stored beside the user avatars.

use std::io;
use std::path::PathBuf;

use super::{Media, read, remove, write_atomic};

impl Media {
    /// A linked account's picture shares the avatar directory; the `link-`
    /// prefix keeps it from ever colliding with a user's UUID-named file.
    pub async fn write_linked_avatar(
        &self,
        provider: &str,
        user_id: &str,
        bytes: Vec<u8>,
    ) -> io::Result<()> {
        write_atomic(self.linked_avatar_path(provider, user_id), bytes).await
    }

    pub async fn read_linked_avatar(&self, provider: &str, user_id: &str) -> io::Result<Vec<u8>> {
        read(self.linked_avatar_path(provider, user_id)).await
    }

    pub async fn delete_linked_avatar(&self, provider: &str, user_id: &str) -> io::Result<()> {
        remove(self.linked_avatar_path(provider, user_id)).await
    }

    fn linked_avatar_path(&self, provider: &str, user_id: &str) -> PathBuf {
        self.avatars_dir.join(format!("link-{provider}-{user_id}"))
    }
}
