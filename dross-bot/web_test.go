package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSplitURLMessage(t *testing.T) {
	cases := []struct {
		name      string
		text      string
		url, rest string
		ok        bool
	}{
		{"bare url", "https://example.com/a", "https://example.com/a", "", true},
		{"url with comment", "https://example.com/a worth a read", "https://example.com/a", "worth a read", true},
		{"url then body lines", "http://example.com\nnotes about it\nmore", "http://example.com", "notes about it\nmore", true},
		{"surrounding whitespace", "  https://example.com \n", "https://example.com", "", true},
		{"url mid-sentence", "check out https://example.com later", "", "", false},
		{"other scheme", "ftp://example.com/file", "", "", false},
		{"command", "/help", "", "", false},
		{"no host", "http://", "", "", false},
		{"plain text", "just a thought", "", "", false},
		{"empty", "", "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			url, rest, ok := splitURLMessage(c.text)
			if url != c.url || rest != c.rest || ok != c.ok {
				t.Errorf("splitURLMessage(%q) = (%q, %q, %v), want (%q, %q, %v)",
					c.text, url, rest, ok, c.url, c.rest, c.ok)
			}
		})
	}
}

// A minimal valid 1x1 PNG.
var tinyPNG = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
	0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
	0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00,
	0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
	0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
}

const testArticle = `<html><head><title>Test Page</title></head><body><article>
<h1>Test Page</h1>
<p>Readability needs a real paragraph or two of prose before it will score a
node as the article, so this test page carries several sentences of filler
about the venerable art of note taking and the perils of link rot.</p>
<p>A second paragraph seals the deal: the zettelkasten remembers what the
network forgets, and a local snapshot keeps the images alongside the words.</p>
<img src="/img.png">
</article></body></html>`

func TestFetchPage(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(testArticle))
	})
	mux.HandleFunc("/img.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(tinyPNG)
	})
	mux.HandleFunc("/doc.pdf", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/pdf")
		_, _ = w.Write([]byte("%PDF-1.4 fake"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	t.Run("html with image inlined", func(t *testing.T) {
		page, err := fetchPage(context.Background(), srv.URL+"/")
		if err != nil {
			t.Fatalf("fetchPage: %v", err)
		}
		if !strings.HasPrefix(page.contentType, "text/html") {
			t.Errorf("contentType = %q, want text/html", page.contentType)
		}
		if page.title != "Test Page" {
			t.Errorf("title = %q, want %q", page.title, "Test Page")
		}
		if !strings.Contains(page.text, "link rot") {
			t.Errorf("extracted text missing body prose: %q", page.text)
		}
		snap := string(page.data)
		if !strings.Contains(snap, "data:image/png;base64") {
			t.Error("snapshot does not inline the image as a data URI")
		}
		if strings.Contains(snap, `src="/img.png"`) {
			t.Error("snapshot still references the remote image")
		}
	})

	t.Run("non-html passes through raw", func(t *testing.T) {
		page, err := fetchPage(context.Background(), srv.URL+"/doc.pdf")
		if err != nil {
			t.Fatalf("fetchPage: %v", err)
		}
		if !strings.HasPrefix(page.contentType, "application/pdf") {
			t.Errorf("contentType = %q, want application/pdf", page.contentType)
		}
		if string(page.data) != "%PDF-1.4 fake" {
			t.Errorf("data = %q, want raw pass-through", page.data)
		}
		if page.title != "" || page.text != "" {
			t.Errorf("non-HTML should skip readability, got title=%q text=%q", page.title, page.text)
		}
	})

	t.Run("timeout honored", func(t *testing.T) {
		slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(2 * time.Second)
		}))
		defer slow.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()
		if _, err := fetchPage(ctx, slow.URL); err == nil {
			t.Error("expected timeout error, got nil")
		}
	})
}

func TestSnapshotName(t *testing.T) {
	cases := []struct {
		name                    string
		title, url, contentType string
		want                    string
	}{
		{"slug from title", "A Great Article: Part 2!", "https://x.com/a", "text/html; charset=utf-8", "a-great-article-part-2.html"},
		{"fallback to host and path", "", "https://blog.example.com/posts/hello", "text/html", "blog-example-com-hello.html"},
		{"pdf extension", "Some Paper", "https://x.com/p.pdf", "application/pdf", "some-paper.pdf"},
		{"unknown type uses url ext", "data", "https://x.com/d.xyz", "application/x-mystery", "data.xyz"},
		{"everything empty", "", "https://", "text/html", "page.html"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := snapshotName(c.title, c.url, c.contentType); got != c.want {
				t.Errorf("snapshotName(%q, %q, %q) = %q, want %q", c.title, c.url, c.contentType, got, c.want)
			}
		})
	}
	t.Run("length capped", func(t *testing.T) {
		got := snapshotName(strings.Repeat("word ", 40), "https://x.com/a", "text/html")
		if len(got) > 66 { // 60-char slug + ".html" + slack
			t.Errorf("slug not capped: %d chars (%q)", len(got), got)
		}
	})
}
