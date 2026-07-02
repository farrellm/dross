package main

// Tests for the proposal git operations (scratch repo, no Telegram) and
// the outbound message splitter.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mustGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := gitRun(dir, args...)
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return out
}

// newRepo builds a notes repo with one base commit and a proposal branch
// adding hub.org, leaving master checked out.
func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	mustGit(t, dir, "init", "-b", "master")
	mustGit(t, dir, "config", "user.name", "test")
	mustGit(t, dir, "config", "user.email", "test@example.org")
	if err := os.WriteFile(filepath.Join(dir, "base.org"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustGit(t, dir, "add", "base.org")
	mustGit(t, dir, "commit", "-m", "base note")

	mustGit(t, dir, "switch", "-c", "proposal/test-hub")
	if err := os.WriteFile(filepath.Join(dir, "hub.org"), []byte("hub note\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustGit(t, dir, "add", "hub.org")
	mustGit(t, dir, "commit", "-m", "dross: synthesis: draft hub note")
	mustGit(t, dir, "switch", "master")
	return dir
}

func TestProposalSummary(t *testing.T) {
	dir := newRepo(t)
	s, err := proposalSummary(dir, "proposal/test-hub")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(s, "dross: synthesis: draft hub note") || !strings.Contains(s, "hub.org") {
		t.Fatalf("summary missing subject or diffstat:\n%s", s)
	}
}

func TestApproveProposal(t *testing.T) {
	dir := newRepo(t)
	if err := approveProposal(dir, "proposal/test-hub"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "hub.org")); err != nil {
		t.Fatalf("hub.org not merged onto master: %v", err)
	}
	if out := mustGit(t, dir, "branch", "--list", "proposal/test-hub"); out != "" {
		t.Fatalf("branch survived approval: %q", out)
	}
}

func TestApproveConflictRestoresTree(t *testing.T) {
	dir := newRepo(t)
	// Conflicting change on master.
	if err := os.WriteFile(filepath.Join(dir, "hub.org"), []byte("conflicting\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustGit(t, dir, "add", "hub.org")
	mustGit(t, dir, "commit", "-m", "conflicting hub")

	if err := approveProposal(dir, "proposal/test-hub"); err == nil {
		t.Fatal("expected merge conflict error")
	}
	if out := mustGit(t, dir, "status", "--porcelain"); out != "" {
		t.Fatalf("working tree dirty after aborted merge:\n%s", out)
	}
	if out := mustGit(t, dir, "branch", "--list", "proposal/test-hub"); out == "" {
		t.Fatal("branch deleted despite failed merge")
	}
}

func TestRejectProposal(t *testing.T) {
	dir := newRepo(t)
	if err := rejectProposal(dir, "proposal/test-hub"); err != nil {
		t.Fatal(err)
	}
	if out := mustGit(t, dir, "branch", "--list", "proposal/test-hub"); out != "" {
		t.Fatalf("branch survived rejection: %q", out)
	}
	if _, err := os.Stat(filepath.Join(dir, "hub.org")); err == nil {
		t.Fatal("hub.org present on master after rejection")
	}
}

func TestValidProposalBranch(t *testing.T) {
	good := []string{"proposal/hub-notes", "proposal/merge_2026.07", "proposal/X1"}
	bad := []string{
		"master", "proposal/", "proposal/has space", "proposal/a..b",
		"proposal/semi;colon", "proposal/" + strings.Repeat("x", 60), "prop/x",
	}
	for _, g := range good {
		if !validProposalBranch(g) {
			t.Errorf("rejected valid branch %q", g)
		}
	}
	for _, b := range bad {
		if validProposalBranch(b) {
			t.Errorf("accepted invalid branch %q", b)
		}
	}
}

func TestSplitMessage(t *testing.T) {
	if got := splitMessage("short", 100); len(got) != 1 || got[0] != "short" {
		t.Fatalf("short message mangled: %#v", got)
	}
	long := strings.Repeat("0123456789\n", 100) // 1100 bytes
	chunks := splitMessage(strings.TrimSpace(long), 100)
	for i, c := range chunks {
		if len(c) > 100 {
			t.Fatalf("chunk %d too long (%d bytes)", i, len(c))
		}
	}
	if joined := strings.Join(chunks, "\n"); joined != strings.TrimSpace(long) {
		t.Fatal("content lost in split")
	}
	// No newlines: must hard-split without breaking UTF-8.
	uni := strings.Repeat("é", 300)
	for i, c := range splitMessage(uni, 100) {
		if len(c) > 100 {
			t.Fatalf("chunk %d too long (%d bytes)", i, len(c))
		}
		if !strings.HasPrefix(c, "é") || !strings.HasSuffix(c, "é") {
			t.Fatalf("chunk %d split inside a rune: %q", i, c)
		}
	}
}
