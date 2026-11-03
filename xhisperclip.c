// xhisperclip: put stdin on the X11 CLIPBOARD marked sensitive.
//
// Like `xclip -selection clipboard -i`, but also offers the KDE password-manager
// hint target (x-kde-passwordManagerHint = "secret"), which clipboard-history tools
// honour. xclip can offer only one target, so dictations pasted into X11 (XWayland)
// apps such as Warp used to land in clipboard history.
//
// Takes the selection, then forks: the parent exits 0 at once and the child serves
// paste requests until another client takes the clipboard. Exits 1 if the text is
// too large for a single property (no INCR) or the selection can't be taken.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

static Atom XA_CLIPBOARD, XA_TARGETS_, XA_UTF8, XA_TEXT_, XA_TIMESTAMP_, XA_MIME_UTF8,
            XA_MIME_PLAIN, XA_HINT;

static void reply(Display *d, XSelectionRequestEvent *req, Atom property) {
  XSelectionEvent ev = {0};
  ev.type = SelectionNotify;
  ev.display = d;
  ev.requestor = req->requestor;
  ev.selection = req->selection;
  ev.target = req->target;
  ev.property = property;
  ev.time = req->time;
  XSendEvent(d, req->requestor, False, 0, (XEvent *)&ev);
  XFlush(d);
}

static void serve(Display *d, XSelectionRequestEvent *req, const char *text, size_t len,
                  Time owned_at) {
  // Obsolete clients may pass None: the target then doubles as the property.
  Atom prop = req->property == None ? req->target : req->property;
  Atom t = req->target;

  if (t == XA_TARGETS_) {
    Atom targets[] = {XA_TARGETS_, XA_TIMESTAMP_, XA_UTF8, XA_STRING, XA_TEXT_,
                      XA_MIME_UTF8, XA_MIME_PLAIN, XA_HINT};
    XChangeProperty(d, req->requestor, prop, XA_ATOM, 32, PropModeReplace,
                    (unsigned char *)targets, sizeof targets / sizeof *targets);
  } else if (t == XA_TIMESTAMP_) {
    long ts = (long)owned_at;
    XChangeProperty(d, req->requestor, prop, XA_INTEGER, 32, PropModeReplace,
                    (unsigned char *)&ts, 1);
  } else if (t == XA_HINT) {
    XChangeProperty(d, req->requestor, prop, t, 8, PropModeReplace,
                    (const unsigned char *)"secret", 6);
  } else if (t == XA_UTF8 || t == XA_STRING || t == XA_TEXT_ || t == XA_MIME_UTF8 ||
             t == XA_MIME_PLAIN) {
    XChangeProperty(d, req->requestor, prop, t == XA_TEXT_ ? XA_UTF8 : t, 8,
                    PropModeReplace, (const unsigned char *)text, (int)len);
  } else {
    prop = None;  // unsupported target (including MULTIPLE): refuse
  }
  reply(d, req, prop);
}

int main(void) {
  // Read all of stdin
  size_t cap = 4096, len = 0, n;
  char *text = malloc(cap);
  if (!text) return 1;
  while ((n = fread(text + len, 1, cap - len, stdin)) > 0) {
    len += n;
    if (len == cap && !(text = realloc(text, cap *= 2))) return 1;
  }

  Display *d = XOpenDisplay(NULL);
  if (!d) { fprintf(stderr, "xhisperclip: cannot open display\n"); return 1; }

  // One property write must hold it all (no INCR); transcriptions are far smaller.
  long max_bytes = XExtendedMaxRequestSize(d);
  if (max_bytes == 0) max_bytes = XMaxRequestSize(d);
  if ((long)len > max_bytes * 4 - 1024) {
    fprintf(stderr, "xhisperclip: text too large\n");
    return 1;
  }

  XA_CLIPBOARD = XInternAtom(d, "CLIPBOARD", False);
  XA_TARGETS_ = XInternAtom(d, "TARGETS", False);
  XA_UTF8 = XInternAtom(d, "UTF8_STRING", False);
  XA_TEXT_ = XInternAtom(d, "TEXT", False);
  XA_TIMESTAMP_ = XInternAtom(d, "TIMESTAMP", False);
  XA_MIME_UTF8 = XInternAtom(d, "text/plain;charset=utf-8", False);
  XA_MIME_PLAIN = XInternAtom(d, "text/plain", False);
  XA_HINT = XInternAtom(d, "x-kde-passwordManagerHint", False);

  Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
  XSelectInput(d, w, PropertyChangeMask);

  // Get a real server timestamp (ICCCM discourages CurrentTime): a zero-length
  // property append generates a PropertyNotify carrying the time.
  XChangeProperty(d, w, XA_WM_NAME, XA_STRING, 8, PropModeAppend, NULL, 0);
  XEvent ev;
  do XNextEvent(d, &ev); while (ev.type != PropertyNotify);
  Time owned_at = ev.xproperty.time;

  XSetSelectionOwner(d, XA_CLIPBOARD, w, owned_at);
  if (XGetSelectionOwner(d, XA_CLIPBOARD) != w) {
    fprintf(stderr, "xhisperclip: could not take the clipboard\n");
    return 1;
  }
  XFlush(d);

  // Serve in the background so the caller can paste right away.
  pid_t pid = fork();
  if (pid < 0) return 1;
  if (pid > 0) _exit(0);
  setsid();
  fclose(stdin); fclose(stdout);

  for (;;) {
    XNextEvent(d, &ev);
    if (ev.type == SelectionClear) break;  // someone else owns the clipboard now
    if (ev.type == SelectionRequest)
      serve(d, &ev.xselectionrequest, text, len, owned_at);
  }
  XCloseDisplay(d);
  return 0;
}
