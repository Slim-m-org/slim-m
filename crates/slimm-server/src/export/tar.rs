// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A streaming ustar writer: entries go straight to the output, so an archive
//! is never held in memory. Sizes past 8 GiB use the GNU base-256 field.

use std::io;
use std::path::Path;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const BLOCK: usize = 512;
const COPY_CHUNK: usize = 64 * 1024;
const MAX_OCTAL_SIZE: u64 = 0o77777777777;

pub struct TarWriter<W> {
    out: W,
    written: u64,
    mtime: u64,
}

impl<W: AsyncWrite + Unpin> TarWriter<W> {
    /// `mtime` is the unix second stamped on every entry.
    pub fn new(out: W, mtime: u64) -> Self {
        Self {
            out,
            written: 0,
            mtime,
        }
    }

    pub async fn append_bytes(&mut self, name: &str, data: &[u8]) -> io::Result<()> {
        self.header(name, data.len() as u64).await?;
        self.out.write_all(data).await?;
        self.written += data.len() as u64;
        self.pad(data.len() as u64).await
    }

    /// Appends the file at `path`, whose length is read once up front.
    pub async fn append_file(&mut self, name: &str, path: &Path) -> io::Result<u64> {
        let file = tokio::fs::File::open(path).await?;
        let len = file.metadata().await?.len();
        self.append_reader(name, file, len).await?;
        Ok(len)
    }

    /// Appends exactly `len` bytes from `reader`; a short reader is an error.
    pub async fn append_reader<R: AsyncRead + Unpin>(
        &mut self,
        name: &str,
        mut reader: R,
        len: u64,
    ) -> io::Result<()> {
        self.header(name, len).await?;
        let mut left = len;
        let mut buf = vec![0u8; COPY_CHUNK];
        while left > 0 {
            let want = usize::try_from(left).map_or(COPY_CHUNK, |n| n.min(COPY_CHUNK));
            let read = reader.read(&mut buf[..want]).await?;
            if read == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "a file ended before its recorded length",
                ));
            }
            self.out.write_all(&buf[..read]).await?;
            left -= read as u64;
        }
        self.written += len;
        self.pad(len).await
    }

    /// Writes the end-of-archive marker, flushes, and returns the bytes written.
    pub async fn finish(mut self) -> io::Result<u64> {
        self.out.write_all(&[0u8; BLOCK * 2]).await?;
        self.written += (BLOCK * 2) as u64;
        self.out.flush().await?;
        Ok(self.written)
    }

    async fn header(&mut self, name: &str, size: u64) -> io::Result<()> {
        let block = header_block(name, size, self.mtime)?;
        self.out.write_all(&block).await?;
        self.written += BLOCK as u64;
        Ok(())
    }

    async fn pad(&mut self, len: u64) -> io::Result<()> {
        let rem = (len % BLOCK as u64) as usize;
        if rem != 0 {
            let pad = BLOCK - rem;
            self.out.write_all(&vec![0u8; pad]).await?;
            self.written += pad as u64;
        }
        Ok(())
    }
}

fn header_block(name: &str, size: u64, mtime: u64) -> io::Result<[u8; BLOCK]> {
    let name = name.as_bytes();
    if name.is_empty() || name.len() > 100 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a tar entry name must be 1 to 100 bytes",
        ));
    }
    let mut block = [0u8; BLOCK];
    block[..name.len()].copy_from_slice(name);
    put_octal(&mut block[100..108], 0o644);
    put_octal(&mut block[108..116], 0);
    put_octal(&mut block[116..124], 0);
    if size > MAX_OCTAL_SIZE {
        block[124] = 0x80;
        block[128..136].copy_from_slice(&size.to_be_bytes());
    } else {
        put_octal(&mut block[124..136], size);
    }
    put_octal(&mut block[136..148], mtime);
    block[148..156].fill(b' ');
    block[156] = b'0';
    block[257..263].copy_from_slice(b"ustar\0");
    block[263..265].copy_from_slice(b"00");
    let sum: u32 = block.iter().map(|b| u32::from(*b)).sum();
    let digits = format!("{sum:06o}\0 ");
    block[148..156].copy_from_slice(digits.as_bytes());
    Ok(block)
}

/// Zero-padded octal filling `field` but for a trailing NUL.
fn put_octal(field: &mut [u8], value: u64) {
    let width = field.len() - 1;
    let digits = format!("{value:0width$o}");
    field[..width].copy_from_slice(digits.as_bytes());
    field[width] = 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn entries_are_block_aligned_and_end_with_two_empty_blocks() {
        let mut out = Vec::new();
        let mut tar = TarWriter::new(&mut out, 0);
        tar.append_bytes("a.txt", b"hello").await.unwrap();
        let total = tar.finish().await.unwrap();
        assert_eq!(total as usize, out.len());
        assert_eq!(out.len(), 512 + 512 + 1024);
        assert_eq!(&out[..5], b"a.txt");
        assert_eq!(&out[512..517], b"hello");
        assert!(out[out.len() - 1024..].iter().all(|b| *b == 0));
    }

    #[tokio::test]
    async fn a_reader_shorter_than_its_length_is_an_error() {
        let mut out = Vec::new();
        let mut tar = TarWriter::new(&mut out, 0);
        let err = tar.append_reader("x", &b"abc"[..], 10).await.unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn a_name_over_one_hundred_bytes_is_refused() {
        assert!(header_block(&"n".repeat(101), 0, 0).is_err());
        assert!(header_block(&"n".repeat(100), 0, 0).is_ok());
    }

    #[test]
    fn sizes_past_eight_gib_use_the_base_256_field() {
        let block = header_block("big", 9 << 30, 0).unwrap();
        assert_eq!(block[124], 0x80);
        assert_eq!(&block[128..136], &(9u64 << 30).to_be_bytes());
    }
}
