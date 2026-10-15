// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

//go:build windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

const (
	detachedProcess       = 0x00000008
	createNewProcessGroup = 0x00000200

	processQueryLimitedInformation = 0x1000
	stillActive                    = 259
)

// start detaches the app so it outlives this launcher, which exits at once.
func start(exe, dir string, args []string) (int, error) {
	cmd := exec.Command(exe, args...)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: detachedProcess | createNewProcessGroup}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	return cmd.Process.Pid, nil
}

// osProcessAlive asks whether the pid still names a running process.
func osProcessAlive(pid int) bool {
	handle, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(handle)
	var code uint32
	if err := syscall.GetExitCodeProcess(handle, &code); err != nil {
		return false
	}
	return code == stillActive
}

// fail shows the reason, because a windowsgui program has no console to print to.
func fail(message string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	title, _ := syscall.UTF16PtrFromString("slim-m")
	text, _ := syscall.UTF16PtrFromString(message)
	user32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
	os.Exit(1)
}
