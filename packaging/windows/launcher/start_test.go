// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTheAppIsStartedWithTheLauncherMarker(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "app.sh")
	put(t, dir, "app.sh", "#!/bin/sh\necho \"$"+launcherEnv+"\" > marker\n")
	if err := os.Chmod(script, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := start(script, dir, nil); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 50; i++ {
		if data, err := os.ReadFile(filepath.Join(dir, "marker")); err == nil && strings.TrimSpace(string(data)) == "1" {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the app did not see the launcher marker")
}
