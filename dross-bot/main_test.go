package main

import "testing"

func TestInboxEntryArgs(t *testing.T) {
	res := `{"id":"abc-123","file":"/notes/some-page.org","hash":"deadbeef"}`
	args := inboxEntryArgs(res, "Some Page", "https://example.com/page")
	if args == nil {
		t.Fatal("expected args, got nil")
	}
	if got, want := args["content"], "Flesh out [[id:abc-123][Some Page]]"; got != want {
		t.Errorf("content = %q, want %q", got, want)
	}
	if got, want := args["title"], "Some Page"; got != want {
		t.Errorf("title = %q, want %q", got, want)
	}
	if got, want := args["source"], "https://example.com/page"; got != want {
		t.Errorf("source = %q, want %q", got, want)
	}

	for name, res := range map[string]string{
		"no id":    `{"file":"/notes/x.org"}`,
		"empty id": `{"id":""}`,
		"garbage":  `not json`,
	} {
		if args := inboxEntryArgs(res, "t", "s"); args != nil {
			t.Errorf("%s: expected nil, got %v", name, args)
		}
	}
}
