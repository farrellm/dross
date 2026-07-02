package main

// Proposal approval flow (CONCEPT.md Decisions): agent proposals are staged
// on proposal/<slug> git branches in the notes repo. `dross-bot propose
// <branch>` announces one with a diff summary and inline Approve/Reject
// buttons; the long-running bot handles the button callbacks — approve
// merges the branch into the current notes checkout (fast-forward when
// possible), reject deletes it. Discussion happens outside the buttons:
// open the branch in Claude Code.

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

const proposalPrefix = "proposal/"

// Callback data is capped at 64 bytes by Telegram; "approve|" leaves 56.
const maxProposalBranch = 56

// validProposalBranch accepts only the branch names our own jobs mint:
// proposal/<slug> with a conservative charset. Callback data crosses the
// network, so this is a security check, not just hygiene.
func validProposalBranch(name string) bool {
	if !strings.HasPrefix(name, proposalPrefix) || len(name) > maxProposalBranch {
		return false
	}
	slug := strings.TrimPrefix(name, proposalPrefix)
	if slug == "" || strings.Contains(slug, "..") {
		return false
	}
	for _, r := range slug {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
		default:
			return false
		}
	}
	return true
}

func gitRun(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err,
			strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

// proposalSummary describes a branch for the approval message: last commit
// subject plus the diffstat against the merge base with the current
// checkout.
func proposalSummary(dir, branch string) (string, error) {
	subject, err := gitRun(dir, "log", "-1", "--format=%s", branch)
	if err != nil {
		return "", err
	}
	stat, err := gitRun(dir, "diff", "--stat", "HEAD..."+branch)
	if err != nil {
		return "", err
	}
	return subject + "\n\n" + stat, nil
}

// approveProposal merges the branch into the current notes checkout
// (fast-forward when possible) and deletes it. On a failed merge the
// working tree is restored and the branch left for another try.
func approveProposal(dir, branch string) error {
	if _, err := gitRun(dir, "-c", "commit.gpgsign=false", "merge", "--no-edit", branch); err != nil {
		if _, abortErr := gitRun(dir, "merge", "--abort"); abortErr != nil {
			log.Printf("merge --abort after failed merge: %v", abortErr)
		}
		return err
	}
	_, err := gitRun(dir, "branch", "-d", branch)
	return err
}

// rejectProposal deletes the branch; its commits stay reachable in reflog
// for a while, which is safety net enough at personal scale.
func rejectProposal(dir, branch string) error {
	_, err := gitRun(dir, "branch", "-D", branch)
	return err
}

// runPropose is the one-shot `dross-bot propose <branch>` mode used by
// proactive jobs after staging a proposal branch.
func runPropose(branch string) {
	notesDir := os.Getenv("DROSS_NOTES_DIR")
	if notesDir == "" {
		log.Fatal("DROSS_NOTES_DIR is not set")
	}
	if !validProposalBranch(branch) {
		log.Fatalf("not a valid proposal branch (want %s<slug>, ≤%d chars): %q",
			proposalPrefix, maxProposalBranch, branch)
	}
	summary, err := proposalSummary(notesDir, branch)
	if err != nil {
		log.Fatalf("propose: %v", err)
	}
	text := "Proposal: " + summary +
		"\n\nBranch: " + branch +
		"\nApprove merges it into the notes; reject deletes the branch. To discuss first, open the branch in Claude Code."

	b, chats := oneShotBot()
	kb := &models.InlineKeyboardMarkup{
		InlineKeyboard: [][]models.InlineKeyboardButton{{
			{Text: "✅ Approve", CallbackData: "approve|" + branch},
			{Text: "🗑 Reject", CallbackData: "reject|" + branch},
		}},
	}
	ctx := context.Background()
	for _, chat := range chats {
		if _, err := b.SendMessage(ctx, &bot.SendMessageParams{
			ChatID:      chat,
			Text:        text,
			ReplyMarkup: kb,
		}); err != nil {
			log.Fatalf("propose: %v", err)
		}
	}
}

// handleCallback resolves an Approve/Reject button press from the serving
// bot: run the git operation, acknowledge the button, and rewrite the
// proposal message with the outcome (dropping the buttons).
func (a *app) handleCallback(ctx context.Context, b *bot.Bot, cb *models.CallbackQuery) {
	ack := func(note string) {
		if _, err := b.AnswerCallbackQuery(ctx, &bot.AnswerCallbackQueryParams{
			CallbackQueryID: cb.ID,
			Text:            note,
		}); err != nil {
			log.Printf("answerCallbackQuery: %v", err)
		}
	}
	msg := cb.Message.Message
	if msg == nil {
		ack("that message is too old to act on")
		return
	}
	if !a.allowed[msg.Chat.ID] {
		log.Printf("ignoring callback from unauthorized chat %d", msg.Chat.ID)
		ack("")
		return
	}
	action, branch, ok := strings.Cut(cb.Data, "|")
	if !ok || !validProposalBranch(branch) {
		ack("malformed proposal callback")
		return
	}

	var outcome string
	var err error
	switch action {
	case "approve":
		err = approveProposal(a.notesDir, branch)
		outcome = "✅ Approved and merged."
	case "reject":
		err = rejectProposal(a.notesDir, branch)
		outcome = "🗑 Rejected; branch deleted."
	default:
		ack("malformed proposal callback")
		return
	}
	if err != nil {
		log.Printf("proposal %s %s: %v", action, branch, err)
		ack("failed — details in chat")
		reply(ctx, b, msg, fmt.Sprintf("Could not %s %s:\n%v", action, branch, err))
		return
	}
	ack(outcome)
	if _, err := b.EditMessageText(ctx, &bot.EditMessageTextParams{
		ChatID:    msg.Chat.ID,
		MessageID: msg.ID,
		Text:      msg.Text + "\n\n" + outcome,
	}); err != nil {
		log.Printf("editMessageText: %v", err)
	}
}
