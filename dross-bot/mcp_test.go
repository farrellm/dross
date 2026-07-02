package main

// Smoke test for the MCP client against a real dross-mcp binary and a
// scratch notes directory. Skipped unless DROSS_MCP_BIN is set (needs the
// binary plus a running database — see dross-mcp/Makefile).

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCaptureSmoke(t *testing.T) {
	bin := os.Getenv("DROSS_MCP_BIN")
	if bin == "" {
		t.Skip("DROSS_MCP_BIN not set")
	}
	notes := t.TempDir()
	c := newMcpClient(bin, notes)
	defer func() {
		c.mu.Lock()
		c.stop()
		c.mu.Unlock()
	}()

	if _, err := c.CallTool("capture", map[string]any{
		"content": "smoke test capture",
		"source":  "telegram",
	}); err != nil {
		t.Fatalf("capture: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(notes, "inbox.org"))
	if err != nil {
		t.Fatalf("inbox.org: %v", err)
	}
	if !strings.Contains(string(data), "smoke test capture") {
		t.Fatalf("inbox.org missing capture:\n%s", data)
	}

	// Tool-level failure surfaces as an error, not a crash.
	if _, err := c.CallTool("capture", map[string]any{"content": "  "}); err == nil {
		t.Fatal("expected error for empty capture")
	}

	// Client still usable afterwards.
	if _, err := c.CallTool("capture", map[string]any{"content": "second capture"}); err != nil {
		t.Fatalf("second capture: %v", err)
	}
}
