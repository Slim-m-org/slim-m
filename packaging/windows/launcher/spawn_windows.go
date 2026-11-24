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

var allowSetForegroundWindow = syscall.NewLazyDLL("user32.dll").NewProc("AllowSetForegroundWindow")

// asfwAny lets whichever process this one starts take the foreground it was given.
const asfwAny = ^uintptr(0)

// start detaches the app so it outlives this launcher, which exits at once.
func start(exe, dir string, args []string) (int, error) {
	_, _, _ = allowSetForegroundWindow.Call(asfwAny)
	cmd := exec.Command(exe, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), launcherEnv+"=1")
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

// osProcessIsApp confirms the pid runs slimm_app.exe, not an unrelated program that reused it.
func osProcessIsApp(pid int) bool {
	image, ok := imagePath(uint32(pid), make([]uint16, syscall.MAX_LONG_PATH))
	return ok && isAppImage(image)
}

// fail shows the reason, because a windowsgui program has no console to print to.
func fail(message string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	title, _ := syscall.UTF16PtrFromString("slim-m")
	text, _ := syscall.UTF16PtrFromString(message)
	user32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
	os.Exit(1)
}

var queryFullProcessImageName = syscall.NewLazyDLL("kernel32.dll").NewProc("QueryFullProcessImageNameW")

// processRunningFrom reports whether any process this user can see runs an exe
// directly in dir; a failed snapshot counts as yes, so the folder is left alone.
func processRunningFrom(dir string) bool {
	images, ok := processImages()
	return !ok || runsFrom(dir, images)
}

// processImages lists the executable path of every process this user may query.
func processImages() ([]string, bool) {
	snapshot, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, false
	}
	defer syscall.CloseHandle(snapshot)
	buf := make([]uint16, syscall.MAX_LONG_PATH)
	var images []string
	var entry syscall.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = syscall.Process32First(snapshot, &entry); err == nil; err = syscall.Process32Next(snapshot, &entry) {
		if path, ok := imagePath(entry.ProcessID, buf); ok {
			images = append(images, path)
		}
	}
	return images, true
}

// imagePath skips a process that has exited but is still listed because another
// holds its handle, as Explorer does for a copy it started from Run or a pin.
func imagePath(pid uint32, buf []uint16) (string, bool) {
	handle, err := syscall.OpenProcess(processQueryLimitedInformation, false, pid)
	if err != nil {
		return "", false
	}
	defer syscall.CloseHandle(handle)
	var code uint32
	if syscall.GetExitCodeProcess(handle, &code) != nil || code != stillActive {
		return "", false
	}
	size := uint32(len(buf))
	ok, _, _ := queryFullProcessImageName.Call(uintptr(handle), 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)))
	if ok == 0 {
		return "", false
	}
	return syscall.UTF16ToString(buf[:size]), true
}
