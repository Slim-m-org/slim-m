// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

//go:build !windows

package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// lockLaunchers is flock on the same lock file, so the tests exercise a real exclusive lock.
func lockLaunchers(root string, wait time.Duration) (func(), bool) {
	path := filepath.Join(root, lockFile)
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if errors.Is(err, fs.ErrPermission) && os.Chmod(path, 0o644) == nil {
		file, err = os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	}
	if err != nil {
		return nil, false
	}
	deadline := time.Now().Add(wait)
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { _ = file.Close() }, true
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) || time.Now().After(deadline) {
			_ = file.Close()
			return nil, false
		}
		time.Sleep(lockPoll)
	}
}
