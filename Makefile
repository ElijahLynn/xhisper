# Makefile for xhisper

CC = gcc
CFLAGS = -O2 -Wall -Wextra
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

all: xhispertool xhisperclip test

xhispertool: xhispertool.c
	$(CC) $(CFLAGS) xhispertool.c -o xhispertool
	ln -sf xhispertool xhispertoold

xhisperclip: xhisperclip.c
	$(CC) $(CFLAGS) xhisperclip.c -o xhisperclip -lX11

test: test.c
	$(CC) $(CFLAGS) test.c -o test

install: xhispertool xhisperclip xhisper.sh
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 xhispertool $(DESTDIR)$(BINDIR)/xhispertool
	ln -sf xhispertool $(DESTDIR)$(BINDIR)/xhispertoold
	install -m 755 xhisperclip $(DESTDIR)$(BINDIR)/xhisperclip
	install -m 755 xhisper.sh $(DESTDIR)$(BINDIR)/xhisper

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/xhisper
	rm -f $(DESTDIR)$(BINDIR)/xhispertool
	rm -f $(DESTDIR)$(BINDIR)/xhispertoold
	rm -f $(DESTDIR)$(BINDIR)/xhisperclip

clean:
	rm -f xhispertool xhispertoold xhisperclip test

perf:
	bash tests/perf.sh

perf-live:
	bash tests/perf.sh --live

test-wayland:
	bash tests/wayland-session.sh

check:
	bash -n xhisper.sh
	bash -n tests/perf.sh
	bash -n tests/wayland-session.sh
	bash -n .githooks/pre-commit
	python3 tests/transcription.py
	python3 tests/clipboard.py
	python3 tests/calibration-stats.py

hooks:
	git config core.hooksPath .githooks

.PHONY: all install uninstall clean perf perf-live test-wayland check hooks
