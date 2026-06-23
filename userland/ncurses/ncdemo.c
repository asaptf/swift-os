// SPDX-License-Identifier: Apache-2.0
//
// ncdemo.c — minimal ncurses proof-of-port for swift-os (milestone NC1).
//
// Links directly against the cross-built static libncurses.a. It exists to
// prove the curses stack works end-to-end on the serial console: terminfo
// resolution (via compiled-in fallbacks — no DB on disk), raw input via
// tcsetattr, cursor addressing on the fixed 24x80 tty, and a clean endwin().
//
// Why C (not Swift, which the project prefers): the curses API is almost
// entirely C preprocessor macros (getch, box, COLS, LINES, stdscr) with no
// linkable symbols, so a Swift caller would need a hand-written shim per macro.
// For a third-party C library a tiny C driver is the honest bridge. See
// docs/NOTES.md ("NC1-ncurses").
//
// Markers (asserted by tests/ncurses_test.sh, printed as plain text so the
// harness never has to parse escape sequences):
//   NCDEMO-START                 — reached main, before initscr
//   NCDEMO-INITFAIL              — setupterm/initscr failed (diagnostic)
//   NCDEMO-OK rows=R cols=C      — drew, read 'q', and ran endwin cleanly

#include <curses.h>
#include <term.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    write(1, "NCDEMO-START\n", 13);

    // Baked binaries inherit an empty environment (every exec path in the
    // userland passes a NULL envp), so getenv("TERM") would be NULL. Force a
    // known terminal that exists in our compiled-in fallbacks.
    setenv("TERM", "vt100", 1);

    // Probe terminfo before initscr so a missing fallback is a clean
    // diagnostic instead of a hang/abort.
    int errret = 0;
    if (setupterm(NULL, 1, &errret) == ERR) {
        printf("NCDEMO-INITFAIL setupterm errret=%d\n", errret);
        fflush(stdout);
        return 1;
    }

    if (initscr() == NULL) {
        printf("NCDEMO-INITFAIL initscr\n");
        fflush(stdout);
        return 1;
    }
    cbreak();
    noecho();
    keypad(stdscr, TRUE);

    int rows = LINES, cols = COLS;

    box(stdscr, 0, 0);
    const char *hello = "hello swift-os";
    mvprintw(rows / 2, (cols - (int)strlen(hello)) / 2, "%s", hello);
    mvprintw(rows - 2, 2, "press q to quit");
    refresh();

    int c;
    while ((c = getch()) != 'q' && c != 'Q' && c != ERR) {
        // ignore other keys; redraw nothing (proof of the input loop)
    }

    endwin();

    printf("NCDEMO-OK rows=%d cols=%d\n", rows, cols);
    fflush(stdout);
    return 0;
}
