package main

// One-shot outbound mode: `dross-bot send` reads a message on stdin and
// delivers it to the configured chat(s). Scheduled proactive jobs (digest,
// gardening, synthesis — see ../proactive/) compose text with claude -p and
// pipe it here; the bot stays the only component that talks to Telegram.

import (
	"context"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/go-telegram/bot"
)

// Telegram caps messages at 4096 UTF-16 code units; splitting at 4000
// bytes keeps a comfortable margin for multi-byte text.
const maxMessageBytes = 4000

func runSend() {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		log.Fatalf("send: reading stdin: %v", err)
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		log.Fatal("send: nothing to send on stdin")
	}

	b, chats := oneShotBot()
	ctx := context.Background()
	for _, chunk := range splitMessage(text, maxMessageBytes) {
		for _, chat := range chats {
			if _, err := b.SendMessage(ctx, &bot.SendMessageParams{
				ChatID: chat,
				Text:   chunk,
			}); err != nil {
				log.Fatalf("send: %v", err)
			}
		}
	}
}

// oneShotBot builds a client for the send/propose modes, where an
// unconfigured chat list is a hard error rather than first-time-setup mode.
func oneShotBot() (*bot.Bot, []int64) {
	token := os.Getenv("TELEGRAM_TOKEN")
	if token == "" {
		log.Fatal("TELEGRAM_TOKEN is not set")
	}
	chats := parseChatIDs(os.Getenv("DROSS_TELEGRAM_CHAT_ID"))
	if len(chats) == 0 {
		log.Fatal("DROSS_TELEGRAM_CHAT_ID is not set")
	}
	b, err := bot.New(token)
	if err != nil {
		log.Fatalf("telegram: %v", err)
	}
	return b, chats
}

func parseChatIDs(env string) []int64 {
	var ids []int64
	for _, s := range strings.Split(env, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		id, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			log.Fatalf("DROSS_TELEGRAM_CHAT_ID: bad chat id %q", s)
		}
		ids = append(ids, id)
	}
	return ids
}

// splitMessage cuts text into chunks of at most max bytes, preferring
// newline boundaries and never splitting a UTF-8 sequence.
func splitMessage(text string, max int) []string {
	var out []string
	for len(text) > max {
		cut := strings.LastIndex(text[:max], "\n")
		if cut <= 0 {
			cut = max
			for cut > 1 && !utf8.RuneStart(text[cut]) {
				cut--
			}
		}
		if chunk := strings.TrimRight(text[:cut], "\n"); chunk != "" {
			out = append(out, chunk)
		}
		text = strings.TrimLeft(text[cut:], "\n")
	}
	if text != "" {
		out = append(out, text)
	}
	return out
}
