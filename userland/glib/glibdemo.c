// SPDX-License-Identifier: Apache-2.0
//
// glibdemo.c — minimal GLib proof-of-port for swift-os (milestone GL1).
//
// Links the cross-built static libglib-2.0.a. It exercises the GLib data
// structures and main-loop clock that Midnight Commander relies on — GString,
// GList, GHashTable, GArray, and g_get_monotonic_time() (the one OS assumption
// that usually blocks GLib on a minimal libc; swift-os provides
// clock_gettime(CLOCK_MONOTONIC) in userland/compat/stubs.c) — and prints a
// plain-text marker the test harness asserts on.
//
// Written in C (the project prefers Swift) because GLib is a C library whose API
// leans on C macros and the GLib type system; a tiny C driver is the honest
// bridge for a third-party C library. See docs/NOTES.md ("GL1-glib").

#include <glib.h>
#include <stdio.h>

int main(void) {
    fputs("GLIBDEMO-START\n", stdout);
    fflush(stdout);

    // GString
    GString *s = g_string_new("hello");
    g_string_append(s, " swift-os");

    // GList
    GList *l = NULL;
    l = g_list_append(l, "alpha");
    l = g_list_append(l, "beta");
    l = g_list_append(l, "gamma");
    guint llen = g_list_length(l);

    // GHashTable
    GHashTable *h = g_hash_table_new(g_str_hash, g_str_equal);
    g_hash_table_insert(h, "key", "value");
    const char *got = g_hash_table_lookup(h, "key");

    // GArray
    GArray *a = g_array_new(FALSE, FALSE, sizeof(gint));
    for (gint i = 0; i < 5; i++) g_array_append_val(a, i);
    gint asum = 0;
    for (guint i = 0; i < a->len; i++) asum += g_array_index(a, gint, i);

    // monotonic clock (GLib main-loop hard requirement)
    gint64 t0 = g_get_monotonic_time();

    // UTF-8 validation (pcre/charset path compiled into libglib)
    gboolean valid = g_utf8_validate(s->str, -1, NULL);

    printf("GLIBDEMO-OK str=\"%s\" list=%u map=%s array_sum=%d utf8=%d mono=%s glib=%d.%d.%d\n",
           s->str, llen, got ? got : "(nil)", asum, valid ? 1 : 0,
           t0 > 0 ? "yes" : "no",
           glib_major_version, glib_minor_version, glib_micro_version);
    fflush(stdout);

    g_array_free(a, TRUE);
    g_hash_table_destroy(h);
    g_list_free(l);
    g_string_free(s, TRUE);
    return 0;
}
