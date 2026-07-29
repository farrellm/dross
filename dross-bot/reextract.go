package main

// One-shot repair mode: `dross-bot reextract` sweeps the org-attach tree for
// documents that were archived but never usefully indexed — a snapshot whose
// readability extract collapsed to its title, a PDF archived before
// pdftotext was installed — and rewrites their .extract.txt sidecars with
// what the current extraction chain produces.
//
// Repairing in place is the supported fix: the server sweeps attach dirs for
// sidecars by directory rather than tracking them per note, so the next tool
// call picks up the new text. Re-running archive-document instead would mint
// a duplicate note.

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The sidecar name and attach-tree layout the server expects
// (data/<2 chars>/<rest>/.extract.txt — see Dross.Index.listExtractFiles).
const extractFileName = ".extract.txt"

// readability scores some rules against the document's own URL, which the
// saved snapshot no longer records. Only the text is wanted here, so a
// placeholder base is enough.
var reextractBase = &url.URL{Scheme: "https", Host: "snapshot.invalid"}

func runReextract(args []string) {
	fs := flag.NewFlagSet("reextract", flag.ExitOnError)
	dryRun := fs.Bool("dry-run", false, "report what would change without writing")
	if err := fs.Parse(args); err != nil {
		log.Fatalf("reextract: %v", err)
	}
	notesDir := os.Getenv("DROSS_NOTES_DIR")
	if notesDir == "" {
		log.Fatal("DROSS_NOTES_DIR is not set")
	}

	dirs, err := attachDirs(notesDir)
	if err != nil {
		log.Fatalf("reextract: %v", err)
	}

	rewrote, scanned := 0, 0
	for _, dir := range dirs {
		scanned++
		rel, relErr := filepath.Rel(notesDir, dir)
		if relErr != nil {
			rel = dir
		}
		current, text, ok := reextractDir(dir)
		if !ok {
			continue
		}
		rewrote++
		verb := "rewriting"
		if *dryRun {
			verb = "would rewrite"
		}
		fmt.Printf("%s %s (%d -> %d chars)\n", verb, rel, len(current), len(text))
		if *dryRun {
			continue
		}
		if err := os.WriteFile(filepath.Join(dir, extractFileName), []byte(text+"\n"), 0o644); err != nil {
			log.Printf("reextract: writing %s: %v", rel, err)
		}
	}

	fmt.Printf("scanned %d attach dirs, %d need rewriting\n", scanned, rewrote)
	if rewrote > 0 && !*dryRun {
		fmt.Printf("review and commit: git -C %s status\n", notesDir)
	}
}

// reextractDir re-runs extraction over an attach dir's archived document and
// reports the replacement text when the sidecar on disk is implausibly thin
// beside it — the same rule that decides the raw-text fallback on capture.
// A dir whose extract already holds real text is left alone.
func reextractDir(dir string) (current, text string, ok bool) {
	current = readExtract(dir)
	if len(current) >= thinExtractBytes {
		return "", "", false
	}
	doc, err := archivedDoc(dir)
	if err != nil || doc == "" {
		return "", "", false
	}

	switch {
	case strings.EqualFold(filepath.Ext(doc), ".html"):
		data, rerr := os.ReadFile(doc)
		if rerr != nil {
			log.Printf("reextract: reading %s: %v", doc, rerr)
			return "", "", false
		}
		_, text, _ = extractHTML(data, reextractBase)
	default:
		text, _ = archiveText(context.Background(), doc)
	}

	if !preferFallback(current, text) {
		return "", "", false
	}
	return current, text, true
}

// archivedDoc picks the document an attach dir is about: the largest HTML
// snapshot if there is one, otherwise the largest non-sidecar file (a PDF
// archived on its own). Size is the tiebreak because an arxiv capture holds
// the abstract page beside the paper.
func archivedDoc(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	best, bestSize := "", int64(-1)
	bestHTML, bestHTMLSize := "", int64(-1)
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		info, ierr := e.Info()
		if ierr != nil {
			continue
		}
		p := filepath.Join(dir, e.Name())
		if info.Size() > bestSize {
			best, bestSize = p, info.Size()
		}
		if strings.EqualFold(filepath.Ext(e.Name()), ".html") && info.Size() > bestHTMLSize {
			bestHTML, bestHTMLSize = p, info.Size()
		}
	}
	if bestHTML != "" {
		return bestHTML, nil
	}
	return best, nil
}

func readExtract(dir string) string {
	data, err := os.ReadFile(filepath.Join(dir, extractFileName))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// attachDirs lists the org-attach leaf dirs (data/<2 chars>/<rest>/), sorted
// so a sweep reports in a stable order.
func attachDirs(notesDir string) ([]string, error) {
	dataDir := filepath.Join(notesDir, "data")
	prefixes, err := os.ReadDir(dataDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var dirs []string
	for _, pre := range prefixes {
		if !pre.IsDir() {
			continue
		}
		rests, rerr := os.ReadDir(filepath.Join(dataDir, pre.Name()))
		if rerr != nil {
			log.Printf("reextract: %v", rerr)
			continue
		}
		for _, rest := range rests {
			if rest.IsDir() {
				dirs = append(dirs, filepath.Join(dataDir, pre.Name(), rest.Name()))
			}
		}
	}
	sort.Strings(dirs)
	return dirs, nil
}
