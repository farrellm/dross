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

// The bot-side follow-up to every archive: an inbox entry linking to the
// stub note (see addInboxEntry). Exercises archive-document + capture
// against the real server.
func TestArchiveInboxSmoke(t *testing.T) {
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
	a := &app{mcp: c, notesDir: notes}

	doc := filepath.Join(t.TempDir(), "smoke.txt")
	if err := os.WriteFile(doc, []byte("smoke document"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := c.CallTool("archive-document", map[string]any{
		"path":   doc,
		"title":  "Smoke Document",
		"source": "https://example.com/smoke",
	})
	if err != nil {
		t.Fatalf("archive-document: %v", err)
	}
	if !a.addInboxEntry(res, "Smoke Document", "https://example.com/smoke") {
		t.Fatal("addInboxEntry failed")
	}

	data, err := os.ReadFile(filepath.Join(notes, "inbox.org"))
	if err != nil {
		t.Fatalf("inbox.org: %v", err)
	}
	inbox := string(data)
	if !strings.Contains(inbox, "Flesh out [[id:") || !strings.Contains(inbox, "][Smoke Document]]") {
		t.Fatalf("inbox.org missing note link:\n%s", inbox)
	}
	if !strings.Contains(inbox, ":SOURCE: https://example.com/smoke") {
		t.Fatalf("inbox.org missing source:\n%s", inbox)
	}
}
