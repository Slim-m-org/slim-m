// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

// start exists so the package builds and tests on the CI and dev hosts that
// are not Windows.
func start(exe, dir string, args []string) (int, error) {
	cmd := exec.Command(exe, args...)
	cmd.Dir = dir
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	return cmd.Process.Pid, nil
}

func osProcessAlive(pid int) bool {
	process, err := os.FindProcess(pid)
	return err == nil && process.Signal(syscall.Signal(0)) == nil
}

func fail(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
