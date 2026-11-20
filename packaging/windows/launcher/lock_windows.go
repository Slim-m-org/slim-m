// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

//go:build windows

package main

import (
	"errors"
	"path/filepath"
	"syscall"
	"time"
)

const errorSharingViolation = syscall.Errno(32)

// lockLaunchers holds the root's lock file open with no sharing, which Windows
// lets only one handle do; the lock goes when the handle closes or the process
// ends. A read-only lock file is made writable once rather than given up on.
func lockLaunchers(root string, wait time.Duration) (func(), bool) {
	path, err := syscall.UTF16PtrFromString(filepath.Join(root, lockFile))
	if err != nil {
		return nil, false
	}
	deadline := time.Now().Add(wait)
	cleared := false
	for {
		handle, err := syscall.CreateFile(path, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil,
			syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL, 0)
		if err == nil {
			return func() { _ = syscall.CloseHandle(handle) }, true
		}
		if errors.Is(err, syscall.ERROR_ACCESS_DENIED) && !cleared {
			cleared = true
			_ = syscall.SetFileAttributes(path, syscall.FILE_ATTRIBUTE_NORMAL)
			continue
		}
		if !errors.Is(err, errorSharingViolation) || time.Now().After(deadline) {
			return nil, false
		}
		time.Sleep(lockPoll)
	}
}
