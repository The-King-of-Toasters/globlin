const std = @import("std");
const expect = std.testing.expect;

// These store character indices into the glob and path strings.
path_index: usize = 0,
glob_index: usize = 0,
// When we hit a * or **, we store the state for backtracking.
next_glob_index: usize = 0,
next_path_index: usize = 0,
// These flags are for * and ** matching.
// allow_sep indicates that path separators are allowed (only in **).
allow_sep: bool = false,
// needs_sep indicates that a path separator is needed following a ** pattern.
needs_sep: bool = false,
// saw_globstar indicates that we previously saw a ** pattern.
saw_globstar: bool = false,

const State = @This();

// This algorithm is based on https://research.swtch.com/glob
pub fn match(glob: []const u8, path: []const u8) bool {
    var state = State{};

    // Store the state when we see an opening '{' brace in a stack.
    // Up to 10 nested braces are supported.
    var brace_stack: [10]State = .{};
    var brace_ptr: usize = 0;
    var longest_brace_match: usize = 0;

    // First, check if the pattern is negated with a leading '!' character.
    // Multiple negations can occur.
    var negated = false;
    while (state.glob_index < glob.len and glob[state.glob_index] == '!') {
        negated = !negated;
        state.glob_index += 1;
    }

    while (state.glob_index < glob.len or state.path_index < path.len) {
        if (!state.allow_sep and
            state.path_index < path.len and
            isSeparator(path[state.path_index]))
        {
            state.next_path_index = 0;
            state.allow_sep = true;
        }

        if (state.glob_index < glob.len) {
            switch (glob[state.glob_index]) {
                '*' => {
                    state.next_glob_index = state.glob_index;
                    state.next_path_index = state.path_index + 1;
                    state.glob_index += 1;

                    state.allow_sep = state.saw_globstar;
                    state.needs_sep = false;

                    // ** allows path separators, whereas * does not.
                    // However, ** must be a full path component, i.e. a/**/b not a**b.
                    if (state.glob_index < glob.len and glob[state.glob_index] == '*') {
                        state.glob_index += 1;
                        if (glob.len == state.glob_index) {
                            state.allow_sep = true;
                        } else if ((state.glob_index < 3 or isSeparator(glob[state.glob_index - 3])) and
                            isSeparator(glob[state.glob_index]))
                        {
                            // Matched a full /**/ segment.
                            // Skip the ending / so we search for the following character.
                            // In effect, this makes the whole segment optional so that a/**/b matches a/b.
                            state.glob_index += 1;

                            // The allows_sep flag allows separator characters in ** matches.
                            // The needs_sep flag ensures that the character just before the next matching
                            // one is a '/', which prevents a/**/b from matching a/bb.
                            state.allow_sep = true;
                            state.needs_sep = true;
                        }
                    }
                    if (state.allow_sep)
                        state.saw_globstar = true;

                    // If the next char is a special brace separator,
                    // skip to the end of the braces so we don't try to match it.
                    if (brace_ptr > 0 and
                        state.glob_index < glob.len and
                        (glob[state.glob_index] == ',' or glob[state.glob_index] == '}'))
                    {
                        if (!skipBraces(glob, &state.glob_index))
                            return false; // invalid pattern!
                    }

                    continue;
                },
                '?' => if (state.path_index < path.len) {
                    if (!isSeparator(path[state.path_index])) {
                        state.glob_index += 1;
                        state.path_index += 1;
                        continue;
                    }
                },
                '[' => if (state.path_index < path.len) {
                    state.glob_index += 1;
                    const c = path[state.path_index];

                    // Check if the character class is negated.
                    var class_negated = false;
                    if (state.glob_index < glob.len and
                        (glob[state.glob_index] == '^' or glob[state.glob_index] == '!'))
                    {
                        class_negated = true;
                        state.glob_index += 1;
                    }

                    // Try each range.
                    const start = state.glob_index;
                    var is_match = false;
                    while (state.glob_index < glob.len and
                        (state.glob_index == start or glob[state.glob_index] != ']'))
                    {
                        var low = glob[state.glob_index];
                        if (!unescape(&low, glob, &state.glob_index))
                            return false; // Invalid pattern
                        state.glob_index += 1;

                        // If there is a - and the following character is not ],
                        // read the range end character.
                        const high = if (state.glob_index + 1 < glob.len and
                            glob[state.glob_index] == '-' and glob[state.glob_index + 1] != ']')
                        blk: {
                            state.glob_index += 1;
                            var h = glob[state.glob_index];
                            if (!unescape(&h, glob, &state.glob_index))
                                return false; // Invalid pattern!
                            state.glob_index += 1;
                            break :blk h;
                        } else low;

                        if (low <= c and c <= high)
                            is_match = true;
                    }
                    if (state.glob_index >= glob.len or glob[state.glob_index] != ']')
                        return false; // Invalid pattern!
                    state.glob_index += 1;
                    if (is_match != class_negated) {
                        state.path_index += 1;
                        continue;
                    }
                },
                '{' => if (state.path_index < path.len) {
                    if (brace_ptr >= brace_stack.len)
                        return false; // Invalid pattern! Too many nested braces.

                    // Push old state to the stack, and reset current state.
                    brace_stack[brace_ptr] = state;
                    brace_ptr += 1;
                    state = State{
                        .path_index = state.path_index,
                        .glob_index = state.glob_index + 1,
                    };
                    continue;
                },

                '}' => if (brace_ptr > 0) {
                    // If we hit the end of the braces, we matched the last option.
                    brace_ptr -= 1;
                    state.glob_index += 1;
                    if (state.path_index < longest_brace_match)
                        state.path_index = longest_brace_match;
                    if (brace_ptr == 0)
                        longest_brace_match = 0;
                    continue;
                },
                ',' => if (brace_ptr > 0) {
                    // If we hit a comma, we matched one of the options!
                    // But we still need to check the others in case there is a longer match.
                    if (state.path_index > longest_brace_match)
                        longest_brace_match = state.path_index;
                    state.path_index = brace_stack[brace_ptr - 1].path_index;
                    state.glob_index += 1;
                    state.next_path_index = 0;
                    state.next_glob_index = 0;
                    continue;
                },
                else => |c| if (state.path_index < path.len) {
                    var cc = c;
                    // Match escaped characters as literals.
                    if (!unescape(&cc, glob, &state.glob_index))
                        return false; // Invalid pattern;

                    if (path[state.path_index] == cc and
                        (!state.needs_sep or
                        (state.path_index > 0 and isSeparator(path[state.path_index - 1]))))
                    {
                        state.glob_index += 1;
                        state.path_index += 1;
                        state.needs_sep = false;
                        state.saw_globstar = false;
                        continue;
                    }
                },
            }
        }
        // If we didn't match, restore state to the previous star pattern.
        if (state.next_path_index > 0 and state.next_path_index <= path.len) {
            state.glob_index = state.next_glob_index;
            state.path_index = state.next_path_index;
            continue;
        }

        if (brace_ptr > 0) {
            // If in braces, find next option and reset path to index where we saw the '{'
            var idx = state.glob_index;
            var found_next = false;
            var braces: i32 = 1;
            while (idx < glob.len) switch (glob[idx]) {
                ',' => if (braces == 1) {
                    // Start matching from here.
                    state.glob_index = idx + 1;
                    state.path_index = brace_stack[brace_ptr - 1].path_index;
                    found_next = true;
                    break;
                } else {
                    idx += 1;
                },
                '{' => {
                    // Skip nested braces.
                    braces += 1;
                    idx += 1;
                },
                '}' => {
                    braces -= 1;
                    idx += 1;
                    if (braces == 0)
                        break;
                },
                '\\' => idx += 2,
                else => idx += 1,
            };

            if (found_next)
                continue;

            if (braces != 0)
                return false; // Invalid pattern!

            // Hit the end. Pop the stack.
            brace_ptr -= 1;

            if (longest_brace_match > 0) {
                state = State{
                    .glob_index = idx,
                    .path_index = longest_brace_match,
                    // Since we matched, preserve these flags.
                    .allow_sep = state.allow_sep,
                    .needs_sep = state.needs_sep,
                    .saw_globstar = state.saw_globstar,
                    // But restore star state if needed later.
                    .next_glob_index = brace_stack[brace_ptr].next_glob_index,
                    .next_path_index = brace_stack[brace_ptr].next_path_index,
                };
                continue;
            } else {
                // Didn't match. Restore state, and check if we need to jump back to a star pattern.
                state = brace_stack[brace_ptr];
                if (state.next_path_index > 0 and state.next_path_index <= path.len) {
                    state.glob_index = state.next_glob_index;
                    state.path_index = state.next_path_index;
                    continue;
                }
            }
        }

        return negated;
    }

    return !negated;
}

inline fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

inline fn unescape(c: *u8, glob: []const u8, glob_index: *usize) bool {
    if (c.* == '\\') {
        glob_index.* += 1;
        if (glob_index.* >= glob.len)
            return false; // Invalid pattern!

        c.* = switch (glob[glob_index.*]) {
            'a' => '\x61',
            'b' => '\x08',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => |cc| cc,
        };
    }

    return true;
}

inline fn skipBraces(glob: []const u8, glob_index: *usize) bool {
    var braces: i32 = 0;
    while (glob_index.* < glob.len) {
        switch (glob[glob_index.*]) {
            '{' => braces += 1,
            '}' => {
                if (braces > 0)
                    braces -= 1
                else
                    break;
            },
            else => {},
        }
        glob_index.* += 1;
    }

    if (glob_index.* < glob.len and glob[glob_index.*] != '}')
        return false; // invalid pattern!

    glob_index.* += 1;
    return true;
}

test "basic" {
    try expect(match("abc", "abc"));
    try expect(match("*", "abc"));
    try expect(match("*", ""));
    try expect(match("**", ""));
    try expect(match("*c", "abc"));
    try expect(!match("*b", "abc"));
    try expect(match("a*", "abc"));
    try expect(!match("b*", "abc"));
    try expect(match("a*", "a"));
    try expect(match("*a", "a"));
    try expect(match("a*b*c*d*e*", "axbxcxdxe"));
    try expect(match("a*b*c*d*e*", "axbxcxdxexxx"));
    try expect(match("a*b?c*x", "abxbbxdbxebxczzx"));
    try expect(!match("a*b?c*x", "abxbbxdbxebxczzy"));

    try expect(match("a/*/test", "a/foo/test"));
    try expect(!match("a/*/test", "a/foo/bar/test"));
    try expect(match("a/**/test", "a/foo/test"));
    try expect(match("a/**/test", "a/foo/bar/test"));
    try expect(match("a/**/b/c", "a/foo/bar/b/c"));
    try expect(match("a\\*b", "a*b"));
    try expect(!match("a\\*b", "axb"));

    try expect(match("[abc]", "a"));
    try expect(match("[abc]", "b"));
    try expect(match("[abc]", "c"));
    try expect(!match("[abc]", "d"));
    try expect(match("x[abc]x", "xax"));
    try expect(match("x[abc]x", "xbx"));
    try expect(match("x[abc]x", "xcx"));
    try expect(!match("x[abc]x", "xdx"));
    try expect(!match("x[abc]x", "xay"));
    try expect(match("[?]", "?"));
    try expect(!match("[?]", "a"));
    try expect(match("[*]", "*"));
    try expect(!match("[*]", "a"));

    try expect(match("[a-cx]", "a"));
    try expect(match("[a-cx]", "b"));
    try expect(match("[a-cx]", "c"));
    try expect(!match("[a-cx]", "d"));
    try expect(match("[a-cx]", "x"));

    try expect(!match("[^abc]", "a"));
    try expect(!match("[^abc]", "b"));
    try expect(!match("[^abc]", "c"));
    try expect(match("[^abc]", "d"));
    try expect(!match("[!abc]", "a"));
    try expect(!match("[!abc]", "b"));
    try expect(!match("[!abc]", "c"));
    try expect(match("[!abc]", "d"));
    try expect(match("[\\!]", "!"));

    try expect(match("a*b*[cy]*d*e*", "axbxcxdxexxx"));
    try expect(match("a*b*[cy]*d*e*", "axbxyxdxexxx"));
    try expect(match("a*b*[cy]*d*e*", "axbxxxyxdxexxx"));

    try expect(match("test.{jpg,png}", "test.jpg"));
    try expect(match("test.{jpg,png}", "test.png"));
    try expect(match("test.{j*g,p*g}", "test.jpg"));
    try expect(match("test.{j*g,p*g}", "test.jpxxxg"));
    try expect(match("test.{j*g,p*g}", "test.jxg"));
    try expect(!match("test.{j*g,p*g}", "test.jnt"));
    try expect(match("test.{j*g,j*c}", "test.jnc"));
    try expect(match("test.{jpg,p*g}", "test.png"));
    try expect(match("test.{jpg,p*g}", "test.pxg"));
    try expect(!match("test.{jpg,p*g}", "test.pnt"));
    try expect(match("test.{jpeg,png}", "test.jpeg"));
    try expect(!match("test.{jpeg,png}", "test.jpg"));
    try expect(match("test.{jpeg,png}", "test.png"));
    try expect(match("test.{jp\\,g,png}", "test.jp,g"));
    try expect(!match("test.{jp\\,g,png}", "test.jxg"));
    try expect(match("test/{foo,bar}/baz", "test/foo/baz"));
    try expect(match("test/{foo,bar}/baz", "test/bar/baz"));
    try expect(!match("test/{foo,bar}/baz", "test/baz/baz"));
    try expect(match("test/{foo*,bar*}/baz", "test/foooooo/baz"));
    try expect(match("test/{foo*,bar*}/baz", "test/barrrrr/baz"));
    try expect(match("test/{*foo,*bar}/baz", "test/xxxxfoo/baz"));
    try expect(match("test/{*foo,*bar}/baz", "test/xxxxbar/baz"));
    try expect(match("test/{foo/**,bar}/baz", "test/bar/baz"));
    try expect(!match("test/{foo/**,bar}/baz", "test/bar/test/baz"));

    try expect(!match("*.txt", "some/big/path/to/the/needle.txt"));
    try expect(match(
        "some/**/needle.{js,tsx,mdx,ts,jsx,txt}",
        "some/a/bigger/path/to/the/crazy/needle.txt",
    ));
    try expect(match(
        "some/**/{a,b,c}/**/needle.txt",
        "some/foo/a/bigger/path/to/the/crazy/needle.txt",
    ));
    try expect(!match(
        "some/**/{a,b,c}/**/needle.txt",
        "some/foo/d/bigger/path/to/the/crazy/needle.txt",
    ));
    try expect(match("a/{a{a,b},b}", "a/aa"));
    try expect(match("a/{a{a,b},b}", "a/ab"));
    try expect(!match("a/{a{a,b},b}", "a/ac"));
    try expect(match("a/{a{a,b},b}", "a/b"));
    try expect(!match("a/{a{a,b},b}", "a/c"));
}

// The below tests are based on Bash and micromatch.
// https://github.com/micromatch/picomatch/blob/master/test/bash.js
test "bash" {
    try expect(!match("a*", "*"));
    try expect(!match("a*", "**"));
    try expect(!match("a*", "\\*"));
    try expect(!match("a*", "a/*"));
    try expect(!match("a*", "b"));
    try expect(!match("a*", "bc"));
    try expect(!match("a*", "bcd"));
    try expect(!match("a*", "bdir/"));
    try expect(!match("a*", "Beware"));
    try expect(match("a*", "a"));
    try expect(match("a*", "ab"));
    try expect(match("a*", "abc"));

    try expect(!match("\\a*", "*"));
    try expect(!match("\\a*", "**"));
    try expect(!match("\\a*", "\\*"));

    try expect(match("\\a*", "a"));
    try expect(!match("\\a*", "a/*"));
    try expect(match("\\a*", "abc"));
    try expect(match("\\a*", "abd"));
    try expect(match("\\a*", "abe"));
    try expect(!match("\\a*", "b"));
    try expect(!match("\\a*", "bb"));
    try expect(!match("\\a*", "bcd"));
    try expect(!match("\\a*", "bdir/"));
    try expect(!match("\\a*", "Beware"));
    try expect(!match("\\a*", "c"));
    try expect(!match("\\a*", "ca"));
    try expect(!match("\\a*", "cb"));
    try expect(!match("\\a*", "d"));
    try expect(!match("\\a*", "dd"));
    try expect(!match("\\a*", "de"));
}

test "bash directories" {
    try expect(!match("b*/", "*"));
    try expect(!match("b*/", "**"));
    try expect(!match("b*/", "\\*"));
    try expect(!match("b*/", "a"));
    try expect(!match("b*/", "a/*"));
    try expect(!match("b*/", "abc"));
    try expect(!match("b*/", "abd"));
    try expect(!match("b*/", "abe"));
    try expect(!match("b*/", "b"));
    try expect(!match("b*/", "bb"));
    try expect(!match("b*/", "bcd"));
    try expect(match("b*/", "bdir/"));
    try expect(!match("b*/", "Beware"));
    try expect(!match("b*/", "c"));
    try expect(!match("b*/", "ca"));
    try expect(!match("b*/", "cb"));
    try expect(!match("b*/", "d"));
    try expect(!match("b*/", "dd"));
    try expect(!match("b*/", "de"));
}

test "bash escaping" {
    try expect(!match("\\^", "*"));
    try expect(!match("\\^", "**"));
    try expect(!match("\\^", "\\*"));
    try expect(!match("\\^", "a"));
    try expect(!match("\\^", "a/*"));
    try expect(!match("\\^", "abc"));
    try expect(!match("\\^", "abd"));
    try expect(!match("\\^", "abe"));
    try expect(!match("\\^", "b"));
    try expect(!match("\\^", "bb"));
    try expect(!match("\\^", "bcd"));
    try expect(!match("\\^", "bdir/"));
    try expect(!match("\\^", "Beware"));
    try expect(!match("\\^", "c"));
    try expect(!match("\\^", "ca"));
    try expect(!match("\\^", "cb"));
    try expect(!match("\\^", "d"));
    try expect(!match("\\^", "dd"));
    try expect(!match("\\^", "de"));

    try expect(match("\\*", "*"));
    // try expect(match("\\*", "\\*"));
    try expect(!match("\\*", "**"));
    try expect(!match("\\*", "a"));
    try expect(!match("\\*", "a/*"));
    try expect(!match("\\*", "abc"));
    try expect(!match("\\*", "abd"));
    try expect(!match("\\*", "abe"));
    try expect(!match("\\*", "b"));
    try expect(!match("\\*", "bb"));
    try expect(!match("\\*", "bcd"));
    try expect(!match("\\*", "bdir/"));
    try expect(!match("\\*", "Beware"));
    try expect(!match("\\*", "c"));
    try expect(!match("\\*", "ca"));
    try expect(!match("\\*", "cb"));
    try expect(!match("\\*", "d"));
    try expect(!match("\\*", "dd"));
    try expect(!match("\\*", "de"));

    try expect(!match("a\\*", "*"));
    try expect(!match("a\\*", "**"));
    try expect(!match("a\\*", "\\*"));
    try expect(!match("a\\*", "a"));
    try expect(!match("a\\*", "a/*"));
    try expect(!match("a\\*", "abc"));
    try expect(!match("a\\*", "abd"));
    try expect(!match("a\\*", "abe"));
    try expect(!match("a\\*", "b"));
    try expect(!match("a\\*", "bb"));
    try expect(!match("a\\*", "bcd"));
    try expect(!match("a\\*", "bdir/"));
    try expect(!match("a\\*", "Beware"));
    try expect(!match("a\\*", "c"));
    try expect(!match("a\\*", "ca"));
    try expect(!match("a\\*", "cb"));
    try expect(!match("a\\*", "d"));
    try expect(!match("a\\*", "dd"));
    try expect(!match("a\\*", "de"));

    try expect(match("*q*", "aqa"));
    try expect(match("*q*", "aaqaa"));
    try expect(!match("*q*", "*"));
    try expect(!match("*q*", "**"));
    try expect(!match("*q*", "\\*"));
    try expect(!match("*q*", "a"));
    try expect(!match("*q*", "a/*"));
    try expect(!match("*q*", "abc"));
    try expect(!match("*q*", "abd"));
    try expect(!match("*q*", "abe"));
    try expect(!match("*q*", "b"));
    try expect(!match("*q*", "bb"));
    try expect(!match("*q*", "bcd"));
    try expect(!match("*q*", "bdir/"));
    try expect(!match("*q*", "Beware"));
    try expect(!match("*q*", "c"));
    try expect(!match("*q*", "ca"));
    try expect(!match("*q*", "cb"));
    try expect(!match("*q*", "d"));
    try expect(!match("*q*", "dd"));
    try expect(!match("*q*", "de"));

    try expect(match("\\**", "*"));
    try expect(match("\\**", "**"));
    try expect(!match("\\**", "\\*"));
    try expect(!match("\\**", "a"));
    try expect(!match("\\**", "a/*"));
    try expect(!match("\\**", "abc"));
    try expect(!match("\\**", "abd"));
    try expect(!match("\\**", "abe"));
    try expect(!match("\\**", "b"));
    try expect(!match("\\**", "bb"));
    try expect(!match("\\**", "bcd"));
    try expect(!match("\\**", "bdir/"));
    try expect(!match("\\**", "Beware"));
    try expect(!match("\\**", "c"));
    try expect(!match("\\**", "ca"));
    try expect(!match("\\**", "cb"));
    try expect(!match("\\**", "d"));
    try expect(!match("\\**", "dd"));
    try expect(!match("\\**", "de"));
}

test "bash classes" {
    try expect(!match("a*[^c]", "*"));
    try expect(!match("a*[^c]", "**"));
    try expect(!match("a*[^c]", "\\*"));
    try expect(!match("a*[^c]", "a"));
    try expect(!match("a*[^c]", "a/*"));
    try expect(!match("a*[^c]", "abc"));
    try expect(match("a*[^c]", "abd"));
    try expect(match("a*[^c]", "abe"));
    try expect(!match("a*[^c]", "b"));
    try expect(!match("a*[^c]", "bb"));
    try expect(!match("a*[^c]", "bcd"));
    try expect(!match("a*[^c]", "bdir/"));
    try expect(!match("a*[^c]", "Beware"));
    try expect(!match("a*[^c]", "c"));
    try expect(!match("a*[^c]", "ca"));
    try expect(!match("a*[^c]", "cb"));
    try expect(!match("a*[^c]", "d"));
    try expect(!match("a*[^c]", "dd"));
    try expect(!match("a*[^c]", "de"));
    try expect(!match("a*[^c]", "baz"));
    try expect(!match("a*[^c]", "bzz"));
    try expect(!match("a*[^c]", "BZZ"));
    try expect(!match("a*[^c]", "beware"));
    try expect(!match("a*[^c]", "BewAre"));

    try expect(match("a[X-]b", "a-b"));
    try expect(match("a[X-]b", "aXb"));

    try expect(!match("[a-y]*[^c]", "*"));
    try expect(match("[a-y]*[^c]", "a*"));
    try expect(!match("[a-y]*[^c]", "**"));
    try expect(!match("[a-y]*[^c]", "\\*"));
    try expect(!match("[a-y]*[^c]", "a"));
    try expect(match("[a-y]*[^c]", "a123b"));
    try expect(!match("[a-y]*[^c]", "a123c"));
    try expect(match("[a-y]*[^c]", "ab"));
    try expect(!match("[a-y]*[^c]", "a/*"));
    try expect(!match("[a-y]*[^c]", "abc"));
    try expect(match("[a-y]*[^c]", "abd"));
    try expect(match("[a-y]*[^c]", "abe"));
    try expect(!match("[a-y]*[^c]", "b"));
    try expect(match("[a-y]*[^c]", "bd"));
    try expect(match("[a-y]*[^c]", "bb"));
    try expect(match("[a-y]*[^c]", "bcd"));
    // try expect(match("[a-y]*[^c]", "bdir/"));
    try expect(!match("[a-y]*[^c]", "Beware"));
    try expect(!match("[a-y]*[^c]", "c"));
    try expect(match("[a-y]*[^c]", "ca"));
    try expect(match("[a-y]*[^c]", "cb"));
    try expect(!match("[a-y]*[^c]", "d"));
    try expect(match("[a-y]*[^c]", "dd"));
    try expect(match("[a-y]*[^c]", "dd"));
    try expect(match("[a-y]*[^c]", "dd"));
    try expect(match("[a-y]*[^c]", "de"));
    try expect(match("[a-y]*[^c]", "baz"));
    try expect(match("[a-y]*[^c]", "bzz"));
    try expect(match("[a-y]*[^c]", "bzz"));
    try expect(!match("[a-y]*[^c]", "BZZ"));
    try expect(match("[a-y]*[^c]", "beware"));
    try expect(!match("[a-y]*[^c]", "BewAre"));

    try expect(match("a\\*b/*", "a*b/ooo"));
    try expect(match("a\\*?/*", "a*b/ooo"));

    try expect(!match("a[b]c", "*"));
    try expect(!match("a[b]c", "**"));
    try expect(!match("a[b]c", "\\*"));
    try expect(!match("a[b]c", "a"));
    try expect(!match("a[b]c", "a/*"));
    try expect(match("a[b]c", "abc"));
    try expect(!match("a[b]c", "abd"));
    try expect(!match("a[b]c", "abe"));
    try expect(!match("a[b]c", "b"));
    try expect(!match("a[b]c", "bb"));
    try expect(!match("a[b]c", "bcd"));
    try expect(!match("a[b]c", "bdir/"));
    try expect(!match("a[b]c", "Beware"));
    try expect(!match("a[b]c", "c"));
    try expect(!match("a[b]c", "ca"));
    try expect(!match("a[b]c", "cb"));
    try expect(!match("a[b]c", "d"));
    try expect(!match("a[b]c", "dd"));
    try expect(!match("a[b]c", "de"));
    try expect(!match("a[b]c", "baz"));
    try expect(!match("a[b]c", "bzz"));
    try expect(!match("a[b]c", "BZZ"));
    try expect(!match("a[b]c", "beware"));
    try expect(!match("a[b]c", "BewAre"));

    try expect(!match("a[\"b\"]c", "*"));
    try expect(!match("a[\"b\"]c", "**"));
    try expect(!match("a[\"b\"]c", "\\*"));
    try expect(!match("a[\"b\"]c", "a"));
    try expect(!match("a[\"b\"]c", "a/*"));
    try expect(match("a[\"b\"]c", "abc"));
    try expect(!match("a[\"b\"]c", "abd"));
    try expect(!match("a[\"b\"]c", "abe"));
    try expect(!match("a[\"b\"]c", "b"));
    try expect(!match("a[\"b\"]c", "bb"));
    try expect(!match("a[\"b\"]c", "bcd"));
    try expect(!match("a[\"b\"]c", "bdir/"));
    try expect(!match("a[\"b\"]c", "Beware"));
    try expect(!match("a[\"b\"]c", "c"));
    try expect(!match("a[\"b\"]c", "ca"));
    try expect(!match("a[\"b\"]c", "cb"));
    try expect(!match("a[\"b\"]c", "d"));
    try expect(!match("a[\"b\"]c", "dd"));
    try expect(!match("a[\"b\"]c", "de"));
    try expect(!match("a[\"b\"]c", "baz"));
    try expect(!match("a[\"b\"]c", "bzz"));
    try expect(!match("a[\"b\"]c", "BZZ"));
    try expect(!match("a[\"b\"]c", "beware"));
    try expect(!match("a[\"b\"]c", "BewAre"));

    try expect(!match("a[\\\\b]c", "*"));
    try expect(!match("a[\\\\b]c", "**"));
    try expect(!match("a[\\\\b]c", "\\*"));
    try expect(!match("a[\\\\b]c", "a"));
    try expect(!match("a[\\\\b]c", "a/*"));
    try expect(match("a[\\\\b]c", "abc"));
    try expect(!match("a[\\\\b]c", "abd"));
    try expect(!match("a[\\\\b]c", "abe"));
    try expect(!match("a[\\\\b]c", "b"));
    try expect(!match("a[\\\\b]c", "bb"));
    try expect(!match("a[\\\\b]c", "bcd"));
    try expect(!match("a[\\\\b]c", "bdir/"));
    try expect(!match("a[\\\\b]c", "Beware"));
    try expect(!match("a[\\\\b]c", "c"));
    try expect(!match("a[\\\\b]c", "ca"));
    try expect(!match("a[\\\\b]c", "cb"));
    try expect(!match("a[\\\\b]c", "d"));
    try expect(!match("a[\\\\b]c", "dd"));
    try expect(!match("a[\\\\b]c", "de"));
    try expect(!match("a[\\\\b]c", "baz"));
    try expect(!match("a[\\\\b]c", "bzz"));
    try expect(!match("a[\\\\b]c", "BZZ"));
    try expect(!match("a[\\\\b]c", "beware"));
    try expect(!match("a[\\\\b]c", "BewAre"));

    try expect(!match("a[\\b]c", "*"));
    try expect(!match("a[\\b]c", "**"));
    try expect(!match("a[\\b]c", "\\*"));
    try expect(!match("a[\\b]c", "a"));
    try expect(!match("a[\\b]c", "a/*"));
    try expect(!match("a[\\b]c", "abc"));
    try expect(!match("a[\\b]c", "abd"));
    try expect(!match("a[\\b]c", "abe"));
    try expect(!match("a[\\b]c", "b"));
    try expect(!match("a[\\b]c", "bb"));
    try expect(!match("a[\\b]c", "bcd"));
    try expect(!match("a[\\b]c", "bdir/"));
    try expect(!match("a[\\b]c", "Beware"));
    try expect(!match("a[\\b]c", "c"));
    try expect(!match("a[\\b]c", "ca"));
    try expect(!match("a[\\b]c", "cb"));
    try expect(!match("a[\\b]c", "d"));
    try expect(!match("a[\\b]c", "dd"));
    try expect(!match("a[\\b]c", "de"));
    try expect(!match("a[\\b]c", "baz"));
    try expect(!match("a[\\b]c", "bzz"));
    try expect(!match("a[\\b]c", "BZZ"));
    try expect(!match("a[\\b]c", "beware"));
    try expect(!match("a[\\b]c", "BewAre"));

    try expect(!match("a[b-d]c", "*"));
    try expect(!match("a[b-d]c", "**"));
    try expect(!match("a[b-d]c", "\\*"));
    try expect(!match("a[b-d]c", "a"));
    try expect(!match("a[b-d]c", "a/*"));
    try expect(match("a[b-d]c", "abc"));
    try expect(!match("a[b-d]c", "abd"));
    try expect(!match("a[b-d]c", "abe"));
    try expect(!match("a[b-d]c", "b"));
    try expect(!match("a[b-d]c", "bb"));
    try expect(!match("a[b-d]c", "bcd"));
    try expect(!match("a[b-d]c", "bdir/"));
    try expect(!match("a[b-d]c", "Beware"));
    try expect(!match("a[b-d]c", "c"));
    try expect(!match("a[b-d]c", "ca"));
    try expect(!match("a[b-d]c", "cb"));
    try expect(!match("a[b-d]c", "d"));
    try expect(!match("a[b-d]c", "dd"));
    try expect(!match("a[b-d]c", "de"));
    try expect(!match("a[b-d]c", "baz"));
    try expect(!match("a[b-d]c", "bzz"));
    try expect(!match("a[b-d]c", "BZZ"));
    try expect(!match("a[b-d]c", "beware"));
    try expect(!match("a[b-d]c", "BewAre"));

    try expect(!match("a?c", "*"));
    try expect(!match("a?c", "**"));
    try expect(!match("a?c", "\\*"));
    try expect(!match("a?c", "a"));
    try expect(!match("a?c", "a/*"));
    try expect(match("a?c", "abc"));
    try expect(!match("a?c", "abd"));
    try expect(!match("a?c", "abe"));
    try expect(!match("a?c", "b"));
    try expect(!match("a?c", "bb"));
    try expect(!match("a?c", "bcd"));
    try expect(!match("a?c", "bdir/"));
    try expect(!match("a?c", "Beware"));
    try expect(!match("a?c", "c"));
    try expect(!match("a?c", "ca"));
    try expect(!match("a?c", "cb"));
    try expect(!match("a?c", "d"));
    try expect(!match("a?c", "dd"));
    try expect(!match("a?c", "de"));
    try expect(!match("a?c", "baz"));
    try expect(!match("a?c", "bzz"));
    try expect(!match("a?c", "BZZ"));
    try expect(!match("a?c", "beware"));
    try expect(!match("a?c", "BewAre"));

    try expect(match("*/man*/bash.*", "man/man1/bash.1"));

    try expect(match("[^a-c]*", "*"));
    try expect(match("[^a-c]*", "**"));
    try expect(!match("[^a-c]*", "a"));
    try expect(!match("[^a-c]*", "a/*"));
    try expect(!match("[^a-c]*", "abc"));
    try expect(!match("[^a-c]*", "abd"));
    try expect(!match("[^a-c]*", "abe"));
    try expect(!match("[^a-c]*", "b"));
    try expect(!match("[^a-c]*", "bb"));
    try expect(!match("[^a-c]*", "bcd"));
    try expect(!match("[^a-c]*", "bdir/"));
    try expect(match("[^a-c]*", "Beware"));
    try expect(match("[^a-c]*", "Beware"));
    try expect(!match("[^a-c]*", "c"));
    try expect(!match("[^a-c]*", "ca"));
    try expect(!match("[^a-c]*", "cb"));
    try expect(match("[^a-c]*", "d"));
    try expect(match("[^a-c]*", "dd"));
    try expect(match("[^a-c]*", "de"));
    try expect(!match("[^a-c]*", "baz"));
    try expect(!match("[^a-c]*", "bzz"));
    try expect(match("[^a-c]*", "BZZ"));
    try expect(!match("[^a-c]*", "beware"));
    try expect(match("[^a-c]*", "BewAre"));
}

test "bash wildmatch" {
    try expect(!match("a[]-]b", "aab"));
    try expect(!match("[ten]", "ten"));
    try expect(match("]", "]"));
    try expect(match("a[]-]b", "a-b"));
    try expect(match("a[]-]b", "a]b"));
    try expect(match("a[]]b", "a]b"));
    try expect(match("a[\\]a\\-]b", "aab"));
    try expect(match("t[a-g]n", "ten"));
    try expect(match("t[^a-g]n", "ton"));
}

test "bash slashmatch" {
    // try expect(!match("f[^eiu][^eiu][^eiu][^eiu][^eiu]r", "foo/bar"));
    try expect(match("foo[/]bar", "foo/bar"));
    try expect(match("f[^eiu][^eiu][^eiu][^eiu][^eiu]r", "foo-bar"));
}

test "bash extra_stars" {
    try expect(!match("a**c", "bbc"));
    try expect(match("a**c", "abc"));
    try expect(!match("a**c", "bbd"));

    try expect(!match("a***c", "bbc"));
    try expect(match("a***c", "abc"));
    try expect(!match("a***c", "bbd"));

    try expect(!match("a*****?c", "bbc"));
    try expect(match("a*****?c", "abc"));
    try expect(!match("a*****?c", "bbc"));

    try expect(match("?*****??", "bbc"));
    try expect(match("?*****??", "abc"));

    try expect(match("*****??", "bbc"));
    try expect(match("*****??", "abc"));

    try expect(match("?*****?c", "bbc"));
    try expect(match("?*****?c", "abc"));

    try expect(match("?***?****c", "bbc"));
    try expect(match("?***?****c", "abc"));
    try expect(!match("?***?****c", "bbd"));

    try expect(match("?***?****?", "bbc"));
    try expect(match("?***?****?", "abc"));

    try expect(match("?***?****", "bbc"));
    try expect(match("?***?****", "abc"));

    try expect(match("*******c", "bbc"));
    try expect(match("*******c", "abc"));

    try expect(match("*******?", "bbc"));
    try expect(match("*******?", "abc"));

    try expect(match("a*cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k***", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k**", "abcdecdhjk"));
    try expect(match("a****c**?**??*****", "abcdecdhjk"));
}

test "stars" {
    try expect(!match("*.js", "a/b/c/z.js"));
    try expect(!match("*.js", "a/b/z.js"));
    try expect(!match("*.js", "a/z.js"));
    try expect(match("*.js", "z.js"));

    // try expect(!match("*/*", "a/.ab"));
    // try expect(!match("*", ".ab"));

    try expect(match("z*.js", "z.js"));
    try expect(match("*/*", "a/z"));
    try expect(match("*/z*.js", "a/z.js"));
    try expect(match("a/z*.js", "a/z.js"));

    try expect(match("*", "ab"));
    try expect(match("*", "abc"));

    try expect(!match("f*", "bar"));
    try expect(!match("*r", "foo"));
    try expect(!match("b*", "foo"));
    try expect(!match("*", "foo/bar"));
    try expect(match("*c", "abc"));
    try expect(match("a*", "abc"));
    try expect(match("a*c", "abc"));
    try expect(match("*r", "bar"));
    try expect(match("b*", "bar"));
    try expect(match("f*", "foo"));

    try expect(match("*abc*", "one abc two"));
    try expect(match("a*b", "a         b"));

    try expect(!match("*a*", "foo"));
    try expect(match("*a*", "bar"));
    try expect(match("*abc*", "oneabctwo"));
    try expect(!match("*-bc-*", "a-b.c-d"));
    try expect(match("*-*.*-*", "a-b.c-d"));
    try expect(match("*-b*c-*", "a-b.c-d"));
    try expect(match("*-b.c-*", "a-b.c-d"));
    try expect(match("*.*", "a-b.c-d"));
    try expect(match("*.*-*", "a-b.c-d"));
    try expect(match("*.*-d", "a-b.c-d"));
    try expect(match("*.c-*", "a-b.c-d"));
    try expect(match("*b.*d", "a-b.c-d"));
    try expect(match("a*.c*", "a-b.c-d"));
    try expect(match("a-*.*-d", "a-b.c-d"));
    try expect(match("*.*", "a.b"));
    try expect(match("*.b", "a.b"));
    try expect(match("a.*", "a.b"));
    try expect(match("a.b", "a.b"));

    try expect(!match("**-bc-**", "a-b.c-d"));
    try expect(match("**-**.**-**", "a-b.c-d"));
    try expect(match("**-b**c-**", "a-b.c-d"));
    try expect(match("**-b.c-**", "a-b.c-d"));
    try expect(match("**.**", "a-b.c-d"));
    try expect(match("**.**-**", "a-b.c-d"));
    try expect(match("**.**-d", "a-b.c-d"));
    try expect(match("**.c-**", "a-b.c-d"));
    try expect(match("**b.**d", "a-b.c-d"));
    try expect(match("a**.c**", "a-b.c-d"));
    try expect(match("a-**.**-d", "a-b.c-d"));
    try expect(match("**.**", "a.b"));
    try expect(match("**.b", "a.b"));
    try expect(match("a.**", "a.b"));
    try expect(match("a.b", "a.b"));

    try expect(match("*/*", "/ab"));
    try expect(match(".", "."));
    try expect(!match("a/", "a/.b"));
    try expect(match("/*", "/ab"));
    try expect(match("/??", "/ab"));
    try expect(match("/?b", "/ab"));
    try expect(match("/*", "/cd"));
    try expect(match("a", "a"));
    try expect(match("a/.*", "a/.b"));
    try expect(match("?/?", "a/b"));
    try expect(match("a/**/j/**/z/*.md", "a/b/c/d/e/j/n/p/o/z/c.md"));
    try expect(match("a/**/z/*.md", "a/b/c/d/e/z/c.md"));
    try expect(match("a/b/c/*.md", "a/b/c/xyz.md"));
    try expect(match("a/b/c/*.md", "a/b/c/xyz.md"));
    try expect(match("a/*/z/.a", "a/b/z/.a"));
    try expect(!match("bz", "a/b/z/.a"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/b.b/aa/c/xyz.md"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/bb/aa/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb.bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bbbb/c/xyz.md"));
    try expect(match("*", "aaa"));
    try expect(match("*", "ab"));
    try expect(match("ab", "ab"));

    try expect(!match("*/*/*", "aaa"));
    try expect(!match("*/*/*", "aaa/bb/aa/rr"));
    try expect(!match("aaa*", "aaa/bba/ccc"));
    // try expect(!match("aaa**", "aaa/bba/ccc"));
    try expect(!match("aaa/*", "aaa/bba/ccc"));
    try expect(!match("aaa/*ccc", "aaa/bba/ccc"));
    try expect(!match("aaa/*z", "aaa/bba/ccc"));
    try expect(!match("*/*/*", "aaa/bbb"));
    try expect(!match("*/*jk*/*i", "ab/zzz/ejkl/hi"));
    try expect(match("*/*/*", "aaa/bba/ccc"));
    try expect(match("aaa/**", "aaa/bba/ccc"));
    try expect(match("aaa/*", "aaa/bbb"));
    try expect(match("*/*z*/*/*i", "ab/zzz/ejkl/hi"));
    try expect(match("*j*i", "abzzzejklhi"));

    try expect(match("*", "a"));
    try expect(match("*", "b"));
    try expect(!match("*", "a/a"));
    try expect(!match("*", "a/a/a"));
    try expect(!match("*", "a/a/b"));
    try expect(!match("*", "a/a/a/a"));
    try expect(!match("*", "a/a/a/a/a"));

    try expect(!match("*/*", "a"));
    try expect(match("*/*", "a/a"));
    try expect(!match("*/*", "a/a/a"));

    try expect(!match("*/*/*", "a"));
    try expect(!match("*/*/*", "a/a"));
    try expect(match("*/*/*", "a/a/a"));
    try expect(!match("*/*/*", "a/a/a/a"));

    try expect(!match("*/*/*/*", "a"));
    try expect(!match("*/*/*/*", "a/a"));
    try expect(!match("*/*/*/*", "a/a/a"));
    try expect(match("*/*/*/*", "a/a/a/a"));
    try expect(!match("*/*/*/*", "a/a/a/a/a"));

    try expect(!match("*/*/*/*/*", "a"));
    try expect(!match("*/*/*/*/*", "a/a"));
    try expect(!match("*/*/*/*/*", "a/a/a"));
    try expect(!match("*/*/*/*/*", "a/a/b"));
    try expect(!match("*/*/*/*/*", "a/a/a/a"));
    try expect(match("*/*/*/*/*", "a/a/a/a/a"));
    try expect(!match("*/*/*/*/*", "a/a/a/a/a/a"));

    try expect(!match("a/*", "a"));
    try expect(match("a/*", "a/a"));
    try expect(!match("a/*", "a/a/a"));
    try expect(!match("a/*", "a/a/a/a"));
    try expect(!match("a/*", "a/a/a/a/a"));

    try expect(!match("a/*/*", "a"));
    try expect(!match("a/*/*", "a/a"));
    try expect(match("a/*/*", "a/a/a"));
    try expect(!match("a/*/*", "b/a/a"));
    try expect(!match("a/*/*", "a/a/a/a"));
    try expect(!match("a/*/*", "a/a/a/a/a"));

    try expect(!match("a/*/*/*", "a"));
    try expect(!match("a/*/*/*", "a/a"));
    try expect(!match("a/*/*/*", "a/a/a"));
    try expect(match("a/*/*/*", "a/a/a/a"));
    try expect(!match("a/*/*/*", "a/a/a/a/a"));

    try expect(!match("a/*/*/*/*", "a"));
    try expect(!match("a/*/*/*/*", "a/a"));
    try expect(!match("a/*/*/*/*", "a/a/a"));
    try expect(!match("a/*/*/*/*", "a/a/b"));
    try expect(!match("a/*/*/*/*", "a/a/a/a"));
    try expect(match("a/*/*/*/*", "a/a/a/a/a"));

    try expect(!match("a/*/a", "a"));
    try expect(!match("a/*/a", "a/a"));
    try expect(match("a/*/a", "a/a/a"));
    try expect(!match("a/*/a", "a/a/b"));
    try expect(!match("a/*/a", "a/a/a/a"));
    try expect(!match("a/*/a", "a/a/a/a/a"));

    try expect(!match("a/*/b", "a"));
    try expect(!match("a/*/b", "a/a"));
    try expect(!match("a/*/b", "a/a/a"));
    try expect(match("a/*/b", "a/a/b"));
    try expect(!match("a/*/b", "a/a/a/a"));
    try expect(!match("a/*/b", "a/a/a/a/a"));

    try expect(!match("*/**/a", "a"));
    try expect(!match("*/**/a", "a/a/b"));
    try expect(match("*/**/a", "a/a"));
    try expect(match("*/**/a", "a/a/a"));
    try expect(match("*/**/a", "a/a/a/a"));
    try expect(match("*/**/a", "a/a/a/a/a"));

    try expect(!match("*/", "a"));
    try expect(!match("*/*", "a"));
    try expect(!match("a/*", "a"));
    // try expect(!match("*/*", "a/"));
    // try expect(!match("a/*", "a/"));
    try expect(!match("*", "a/a"));
    try expect(!match("*/", "a/a"));
    try expect(!match("*/", "a/x/y"));
    try expect(!match("*/*", "a/x/y"));
    try expect(!match("a/*", "a/x/y"));
    // try expect(match("*", "a/"));
    try expect(match("*", "a"));
    try expect(match("*/", "a/"));
    try expect(match("*{,/}", "a/"));
    try expect(match("*/*", "a/a"));
    try expect(match("a/*", "a/a"));

    try expect(!match("a/**/*.txt", "a.txt"));
    try expect(match("a/**/*.txt", "a/x/y.txt"));
    try expect(!match("a/**/*.txt", "a/x/y/z"));

    try expect(!match("a/*.txt", "a.txt"));
    try expect(match("a/*.txt", "a/b.txt"));
    try expect(!match("a/*.txt", "a/x/y.txt"));
    try expect(!match("a/*.txt", "a/x/y/z"));

    try expect(match("a*.txt", "a.txt"));
    try expect(!match("a*.txt", "a/b.txt"));
    try expect(!match("a*.txt", "a/x/y.txt"));
    try expect(!match("a*.txt", "a/x/y/z"));

    try expect(match("*.txt", "a.txt"));
    try expect(!match("*.txt", "a/b.txt"));
    try expect(!match("*.txt", "a/x/y.txt"));
    try expect(!match("*.txt", "a/x/y/z"));

    try expect(!match("a*", "a/b"));
    try expect(!match("a/**/b", "a/a/bb"));
    try expect(!match("a/**/b", "a/bb"));

    try expect(!match("*/**", "foo"));
    // try expect(!match("**/", "foo/bar"));
    try expect(!match("**/*/", "foo/bar"));
    try expect(!match("*/*/", "foo/bar"));

    try expect(match("**/..", "/home/foo/.."));
    // try expect(match("**/a", "a"));
    try expect(match("**", "a/a"));
    try expect(match("a/**", "a/a"));
    try expect(match("a/**", "a/"));
    // try expect(match("a/**", "a"));
    // try expect(!match("**/", "a/a"));
    // try expect(match("**/a/**", "a"));
    // try expect(match("a/**", "a"));
    // try expect(!match("**/", "a/a"));
    try expect(match("*/**/a", "a/a"));
    // try expect(match("a/**", "a"));
    try expect(match("*/**", "foo/"));
    try expect(match("**/*", "foo/bar"));
    try expect(match("*/*", "foo/bar"));
    try expect(match("*/**", "foo/bar"));
    try expect(match("**/", "foo/bar/"));
    try expect(match("**/*", "foo/bar/"));
    try expect(match("**/*/", "foo/bar/"));
    try expect(match("*/**", "foo/bar/"));
    try expect(match("*/*/", "foo/bar/"));

    try expect(!match("*/foo", "bar/baz/foo"));
    try expect(!match("**/bar/*", "deep/foo/bar"));
    try expect(!match("*/bar/**", "deep/foo/bar/baz/x"));
    try expect(!match("/*", "ef"));
    try expect(!match("foo?bar", "foo/bar"));
    try expect(!match("**/bar*", "foo/bar/baz"));
    // try expect(!match("**/bar**", "foo/bar/baz"));
    try expect(!match("foo**bar", "foo/baz/bar"));
    try expect(!match("foo*bar", "foo/baz/bar"));
    // try expect(match("foo/**", "foo"));
    try expect(match("/*", "/ab"));
    try expect(match("/*", "/cd"));
    try expect(match("/*", "/ef"));
    try expect(match("a/**/j/**/z/*.md", "a/b/j/c/z/x.md"));
    try expect(match("a/**/j/**/z/*.md", "a/j/z/x.md"));

    try expect(match("**/foo", "bar/baz/foo"));
    try expect(match("**/bar/*", "deep/foo/bar/baz"));
    try expect(match("**/bar/**", "deep/foo/bar/baz/"));
    try expect(match("**/bar/*/*", "deep/foo/bar/baz/x"));
    try expect(match("foo/**/**/bar", "foo/b/a/z/bar"));
    try expect(match("foo/**/bar", "foo/b/a/z/bar"));
    try expect(match("foo/**/**/bar", "foo/bar"));
    try expect(match("foo/**/bar", "foo/bar"));
    try expect(match("*/bar/**", "foo/bar/baz/x"));
    try expect(match("foo/**/**/bar", "foo/baz/bar"));
    try expect(match("foo/**/bar", "foo/baz/bar"));
    try expect(match("**/foo", "XXX/foo"));
}

test "globstars" {
    try expect(match("**/*.js", "a/b/c/d.js"));
    try expect(match("**/*.js", "a/b/c.js"));
    try expect(match("**/*.js", "a/b.js"));
    try expect(match("a/b/**/*.js", "a/b/c/d/e/f.js"));
    try expect(match("a/b/**/*.js", "a/b/c/d/e.js"));
    try expect(match("a/b/c/**/*.js", "a/b/c/d.js"));
    try expect(match("a/b/**/*.js", "a/b/c/d.js"));
    try expect(match("a/b/**/*.js", "a/b/d.js"));
    try expect(!match("a/b/**/*.js", "a/d.js"));
    try expect(!match("a/b/**/*.js", "d.js"));

    try expect(!match("**c", "a/b/c"));
    try expect(!match("a/**c", "a/b/c"));
    try expect(!match("a/**z", "a/b/c"));
    try expect(!match("a/**b**/c", "a/b/c/b/c"));
    try expect(!match("a/b/c**/*.js", "a/b/c/d/e.js"));
    try expect(match("a/**/b/**/c", "a/b/c/b/c"));
    try expect(match("a/**b**/c", "a/aba/c"));
    try expect(match("a/**b**/c", "a/b/c"));
    try expect(match("a/b/c**/*.js", "a/b/c/d.js"));

    try expect(!match("a/**/*", "a"));
    try expect(!match("a/**/**/*", "a"));
    try expect(!match("a/**/**/**/*", "a"));
    try expect(!match("**/a", "a/"));
    // try expect(!match("a/**/*", "a/"));
    // try expect(!match("a/**/**/*", "a/"));
    // try expect(!match("a/**/**/**/*", "a/"));
    try expect(!match("**/a", "a/b"));
    try expect(!match("a/**/j/**/z/*.md", "a/b/c/j/e/z/c.txt"));
    try expect(!match("a/**/b", "a/bb"));
    try expect(!match("**/a", "a/c"));
    try expect(!match("**/a", "a/b"));
    try expect(!match("**/a", "a/x/y"));
    try expect(!match("**/a", "a/b/c/d"));
    try expect(match("**", "a"));
    // try expect(match("**/a", "a"));
    // try expect(match("a/**", "a"));
    try expect(match("**", "a/"));
    // try expect(match("**/a/**", "a/"));
    try expect(match("a/**", "a/"));
    // try expect(match("a/**/**", "a/"));
    try expect(match("**/a", "a/a"));
    try expect(match("**", "a/b"));
    try expect(match("*/*", "a/b"));
    try expect(match("a/**", "a/b"));
    try expect(match("a/**/*", "a/b"));
    try expect(match("a/**/**/*", "a/b"));
    try expect(match("a/**/**/**/*", "a/b"));
    try expect(match("a/**/b", "a/b"));
    try expect(match("**", "a/b/c"));
    try expect(match("**/*", "a/b/c"));
    try expect(match("**/**", "a/b/c"));
    try expect(match("*/**", "a/b/c"));
    try expect(match("a/**", "a/b/c"));
    try expect(match("a/**/*", "a/b/c"));
    try expect(match("a/**/**/*", "a/b/c"));
    try expect(match("a/**/**/**/*", "a/b/c"));
    try expect(match("**", "a/b/c/d"));
    try expect(match("a/**", "a/b/c/d"));
    try expect(match("a/**/*", "a/b/c/d"));
    try expect(match("a/**/**/*", "a/b/c/d"));
    try expect(match("a/**/**/**/*", "a/b/c/d"));
    try expect(match("a/b/**/c/**/*.*", "a/b/c/d.e"));
    try expect(match("a/**/f/*.md", "a/b/c/d/e/f/g.md"));
    try expect(match("a/**/f/**/k/*.md", "a/b/c/d/e/f/g/h/i/j/k/l.md"));
    try expect(match("a/b/c/*.md", "a/b/c/def.md"));
    try expect(match("a/*/c/*.md", "a/bb.bb/c/ddd.md"));
    try expect(match("a/**/f/*.md", "a/bb.bb/cc/d.d/ee/f/ggg.md"));
    try expect(match("a/**/f/*.md", "a/bb.bb/cc/dd/ee/f/ggg.md"));
    try expect(match("a/*/c/*.md", "a/bb/c/ddd.md"));
    try expect(match("a/*/c/*.md", "a/bbbb/c/ddd.md"));

    try expect(match("foo/bar/**/one/**/*.*", "foo/bar/baz/one/image.png"));
    try expect(match("foo/bar/**/one/**/*.*", "foo/bar/baz/one/two/image.png"));
    try expect(match("foo/bar/**/one/**/*.*", "foo/bar/baz/one/two/three/image.png"));
    try expect(!match("a/b/**/f", "a/b/c/d/"));
    // try expect(match("a/**", "a"));
    try expect(match("**", "a"));
    // try expect(match("a{,/**}", "a"));
    try expect(match("**", "a/"));
    try expect(match("a/**", "a/"));
    try expect(match("**", "a/b/c/d"));
    try expect(match("**", "a/b/c/d/"));
    try expect(match("**/**", "a/b/c/d/"));
    try expect(match("**/b/**", "a/b/c/d/"));
    try expect(match("a/b/**", "a/b/c/d/"));
    try expect(match("a/b/**/", "a/b/c/d/"));
    try expect(match("a/b/**/c/**/", "a/b/c/d/"));
    try expect(match("a/b/**/c/**/d/", "a/b/c/d/"));
    try expect(match("a/b/**/**/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/c/**/d/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/d/**/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/d/**/*.*", "a/b/c/d/g/e.f"));
    try expect(match("a/b/**/d/**/*.*", "a/b/c/d/g/g/e.f"));
    try expect(match("a/b-*/**/z.js", "a/b-c/z.js"));
    try expect(match("a/b-*/**/z.js", "a/b-c/d/e/z.js"));

    try expect(match("*/*", "a/b"));
    try expect(match("a/b/c/*.md", "a/b/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb.bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bbbb/c/xyz.md"));

    try expect(match("**/*", "a/b/c"));
    try expect(match("**/**", "a/b/c"));
    try expect(match("*/**", "a/b/c"));
    try expect(match("a/**/j/**/z/*.md", "a/b/c/d/e/j/n/p/o/z/c.md"));
    try expect(match("a/**/z/*.md", "a/b/c/d/e/z/c.md"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/b.b/aa/c/xyz.md"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/bb/aa/c/xyz.md"));
    try expect(!match("a/**/j/**/z/*.md", "a/b/c/j/e/z/c.txt"));
    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/c/xyz.md"));
    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/d/xyz.md"));
    // try expect(!match("a/**/", "a/b"));
    // try expect(!match("**/*", "a/b/.js/c.txt"));
    // try expect(!match("a/**/", "a/b/c/d"));
    // try expect(!match("a/**/", "a/bb"));
    // try expect(!match("a/**/", "a/cb"));
    try expect(match("/**", "/a/b"));
    try expect(match("**/*", "a.b"));
    try expect(match("**/*", "a.js"));
    try expect(match("**/*.js", "a.js"));
    try expect(match("a/**/", "a/"));
    try expect(match("**/*.js", "a/a.js"));
    try expect(match("**/*.js", "a/a/b.js"));
    try expect(match("a/**/b", "a/b"));
    try expect(match("a/**b", "a/b"));
    try expect(match("**/*.md", "a/b.md"));
    try expect(match("**/*", "a/b/c.js"));
    try expect(match("**/*", "a/b/c.txt"));
    try expect(match("a/**/", "a/b/c/d/"));
    try expect(match("**/*", "a/b/c/d/a.js"));
    try expect(match("a/b/**/*.js", "a/b/c/z.js"));
    try expect(match("a/b/**/*.js", "a/b/z.js"));
    try expect(match("**/*", "ab"));
    try expect(match("**/*", "ab/c"));
    try expect(match("**/*", "ab/c/d"));
    try expect(match("**/*", "abc.js"));

    // try expect(!match("**/", "a"));
    try expect(!match("**/a/*", "a"));
    try expect(!match("**/a/*/*", "a"));
    try expect(!match("*/a/**", "a"));
    try expect(!match("a/**/*", "a"));
    try expect(!match("a/**/**/*", "a"));
    // try expect(!match("**/", "a/b"));
    try expect(!match("**/b/*", "a/b"));
    try expect(!match("**/b/*/*", "a/b"));
    try expect(!match("b/**", "a/b"));
    // try expect(!match("**/", "a/b/c"));
    try expect(!match("**/**/b", "a/b/c"));
    try expect(!match("**/b", "a/b/c"));
    try expect(!match("**/b/*/*", "a/b/c"));
    try expect(!match("b/**", "a/b/c"));
    // try expect(!match("**/", "a/b/c/d"));
    try expect(!match("**/d/*", "a/b/c/d"));
    try expect(!match("b/**", "a/b/c/d"));
    try expect(match("**", "a"));
    try expect(match("**/**", "a"));
    try expect(match("**/**/*", "a"));
    // try expect(match("**/**/a", "a"));
    // try expect(match("**/a", "a"));
    // try expect(match("**/a/**", "a"));
    // try expect(match("a/**", "a"));
    try expect(match("**", "a/b"));
    try expect(match("**/**", "a/b"));
    try expect(match("**/**/*", "a/b"));
    try expect(match("**/**/b", "a/b"));
    try expect(match("**/b", "a/b"));
    // try expect(match("**/b/**", "a/b"));
    // try expect(match("*/b/**", "a/b"));
    try expect(match("a/**", "a/b"));
    try expect(match("a/**/*", "a/b"));
    try expect(match("a/**/**/*", "a/b"));
    try expect(match("**", "a/b/c"));
    try expect(match("**/**", "a/b/c"));
    try expect(match("**/**/*", "a/b/c"));
    try expect(match("**/b/*", "a/b/c"));
    try expect(match("**/b/**", "a/b/c"));
    try expect(match("*/b/**", "a/b/c"));
    try expect(match("a/**", "a/b/c"));
    try expect(match("a/**/*", "a/b/c"));
    try expect(match("a/**/**/*", "a/b/c"));
    try expect(match("**", "a/b/c/d"));
    try expect(match("**/**", "a/b/c/d"));
    try expect(match("**/**/*", "a/b/c/d"));
    try expect(match("**/**/d", "a/b/c/d"));
    try expect(match("**/b/**", "a/b/c/d"));
    try expect(match("**/b/*/*", "a/b/c/d"));
    try expect(match("**/d", "a/b/c/d"));
    try expect(match("*/b/**", "a/b/c/d"));
    try expect(match("a/**", "a/b/c/d"));
    try expect(match("a/**/*", "a/b/c/d"));
    try expect(match("a/**/**/*", "a/b/c/d"));
}

test "utf8" {
    try expect(match("フ*/**/*", "フォルダ/aaa.js"));
    try expect(match("フォ*/**/*", "フォルダ/aaa.js"));
    try expect(match("フォル*/**/*", "フォルダ/aaa.js"));
    try expect(match("フ*ル*/**/*", "フォルダ/aaa.js"));
    try expect(match("フォルダ/**/*", "フォルダ/aaa.js"));
}

test "negation" {
    try expect(!match("!*", "abc"));
    try expect(!match("!abc", "abc"));
    try expect(!match("*!.md", "bar.md"));
    try expect(!match("foo!.md", "bar.md"));
    try expect(!match("\\!*!*.md", "foo!.md"));
    try expect(!match("\\!*!*.md", "foo!bar.md"));
    try expect(match("*!*.md", "!foo!.md"));
    try expect(match("\\!*!*.md", "!foo!.md"));
    try expect(match("!*foo", "abc"));
    try expect(match("!foo*", "abc"));
    try expect(match("!xyz", "abc"));
    try expect(match("*!*.*", "ba!r.js"));
    try expect(match("*.md", "bar.md"));
    try expect(match("*!*.*", "foo!.md"));
    try expect(match("*!*.md", "foo!.md"));
    try expect(match("*!.md", "foo!.md"));
    try expect(match("*.md", "foo!.md"));
    try expect(match("foo!.md", "foo!.md"));
    try expect(match("*!*.md", "foo!bar.md"));
    try expect(match("*b*.md", "foobar.md"));

    try expect(!match("a!!b", "a"));
    try expect(!match("a!!b", "aa"));
    try expect(!match("a!!b", "a/b"));
    try expect(!match("a!!b", "a!b"));
    try expect(match("a!!b", "a!!b"));
    try expect(!match("a!!b", "a/!!/b"));

    try expect(!match("!a/b", "a/b"));
    try expect(match("!a/b", "a"));
    try expect(match("!a/b", "a.b"));
    try expect(match("!a/b", "a/a"));
    try expect(match("!a/b", "a/c"));
    try expect(match("!a/b", "b/a"));
    try expect(match("!a/b", "b/b"));
    try expect(match("!a/b", "b/c"));

    try expect(!match("!abc", "abc"));
    try expect(match("!!abc", "abc"));
    try expect(!match("!!!abc", "abc"));
    try expect(match("!!!!abc", "abc"));
    try expect(!match("!!!!!abc", "abc"));
    try expect(match("!!!!!!abc", "abc"));
    try expect(!match("!!!!!!!abc", "abc"));
    try expect(match("!!!!!!!!abc", "abc"));

    // try expect(!match("!(*/*)", "a/a"));
    // try expect(!match("!(*/*)", "a/b"));
    // try expect(!match("!(*/*)", "a/c"));
    // try expect(!match("!(*/*)", "b/a"));
    // try expect(!match("!(*/*)", "b/b"));
    // try expect(!match("!(*/*)", "b/c"));
    // try expect(!match("!(*/b)", "a/b"));
    // try expect(!match("!(*/b)", "b/b"));
    // try expect(!match("!(a/b)", "a/b"));
    try expect(!match("!*", "a"));
    try expect(!match("!*", "a.b"));
    try expect(!match("!*/*", "a/a"));
    try expect(!match("!*/*", "a/b"));
    try expect(!match("!*/*", "a/c"));
    try expect(!match("!*/*", "b/a"));
    try expect(!match("!*/*", "b/b"));
    try expect(!match("!*/*", "b/c"));
    try expect(!match("!*/b", "a/b"));
    try expect(!match("!*/b", "b/b"));
    try expect(!match("!*/c", "a/c"));
    try expect(!match("!*/c", "a/c"));
    try expect(!match("!*/c", "b/c"));
    try expect(!match("!*/c", "b/c"));
    try expect(!match("!*a*", "bar"));
    try expect(!match("!*a*", "fab"));
    // try expect(!match("!a/(*)", "a/a"));
    // try expect(!match("!a/(*)", "a/b"));
    // try expect(!match("!a/(*)", "a/c"));
    // try expect(!match("!a/(b)", "a/b"));
    try expect(!match("!a/*", "a/a"));
    try expect(!match("!a/*", "a/b"));
    try expect(!match("!a/*", "a/c"));
    try expect(!match("!f*b", "fab"));
    // try expect(match("!(*/*)", "a"));
    // try expect(match("!(*/*)", "a.b"));
    // try expect(match("!(*/b)", "a"));
    // try expect(match("!(*/b)", "a.b"));
    // try expect(match("!(*/b)", "a/a"));
    // try expect(match("!(*/b)", "a/c"));
    // try expect(match("!(*/b)", "b/a"));
    // try expect(match("!(*/b)", "b/c"));
    // try expect(match("!(a/b)", "a"));
    // try expect(match("!(a/b)", "a.b"));
    // try expect(match("!(a/b)", "a/a"));
    // try expect(match("!(a/b)", "a/c"));
    // try expect(match("!(a/b)", "b/a"));
    // try expect(match("!(a/b)", "b/b"));
    // try expect(match("!(a/b)", "b/c"));
    try expect(match("!*", "a/a"));
    try expect(match("!*", "a/b"));
    try expect(match("!*", "a/c"));
    try expect(match("!*", "b/a"));
    try expect(match("!*", "b/b"));
    try expect(match("!*", "b/c"));
    try expect(match("!*/*", "a"));
    try expect(match("!*/*", "a.b"));
    try expect(match("!*/b", "a"));
    try expect(match("!*/b", "a.b"));
    try expect(match("!*/b", "a/a"));
    try expect(match("!*/b", "a/c"));
    try expect(match("!*/b", "b/a"));
    try expect(match("!*/b", "b/c"));
    try expect(match("!*/c", "a"));
    try expect(match("!*/c", "a.b"));
    try expect(match("!*/c", "a/a"));
    try expect(match("!*/c", "a/b"));
    try expect(match("!*/c", "b/a"));
    try expect(match("!*/c", "b/b"));
    try expect(match("!*a*", "foo"));
    // try expect(match("!a/(*)", "a"));
    // try expect(match("!a/(*)", "a.b"));
    // try expect(match("!a/(*)", "b/a"));
    // try expect(match("!a/(*)", "b/b"));
    // try expect(match("!a/(*)", "b/c"));
    // try expect(match("!a/(b)", "a"));
    // try expect(match("!a/(b)", "a.b"));
    // try expect(match("!a/(b)", "a/a"));
    // try expect(match("!a/(b)", "a/c"));
    // try expect(match("!a/(b)", "b/a"));
    // try expect(match("!a/(b)", "b/b"));
    // try expect(match("!a/(b)", "b/c"));
    try expect(match("!a/*", "a"));
    try expect(match("!a/*", "a.b"));
    try expect(match("!a/*", "b/a"));
    try expect(match("!a/*", "b/b"));
    try expect(match("!a/*", "b/c"));
    try expect(match("!f*b", "bar"));
    try expect(match("!f*b", "foo"));

    try expect(!match("!.md", ".md"));
    try expect(match("!**/*.md", "a.js"));
    // try expect(!match("!**/*.md", "b.md"));
    try expect(match("!**/*.md", "c.txt"));
    try expect(match("!*.md", "a.js"));
    try expect(!match("!*.md", "b.md"));
    try expect(match("!*.md", "c.txt"));
    try expect(!match("!*.md", "abc.md"));
    try expect(match("!*.md", "abc.txt"));
    try expect(!match("!*.md", "foo.md"));
    try expect(match("!.md", "foo.md"));

    try expect(match("!*.md", "a.js"));
    try expect(match("!*.md", "b.txt"));
    try expect(!match("!*.md", "c.md"));
    try expect(!match("!a/*/a.js", "a/a/a.js"));
    try expect(!match("!a/*/a.js", "a/b/a.js"));
    try expect(!match("!a/*/a.js", "a/c/a.js"));
    try expect(!match("!a/*/*/a.js", "a/a/a/a.js"));
    try expect(match("!a/*/*/a.js", "b/a/b/a.js"));
    try expect(match("!a/*/*/a.js", "c/a/c/a.js"));
    try expect(!match("!a/a*.txt", "a/a.txt"));
    try expect(match("!a/a*.txt", "a/b.txt"));
    try expect(match("!a/a*.txt", "a/c.txt"));
    try expect(!match("!a.a*.txt", "a.a.txt"));
    try expect(match("!a.a*.txt", "a.b.txt"));
    try expect(match("!a.a*.txt", "a.c.txt"));
    try expect(!match("!a/*.txt", "a/a.txt"));
    try expect(!match("!a/*.txt", "a/b.txt"));
    try expect(!match("!a/*.txt", "a/c.txt"));

    try expect(match("!*.md", "a.js"));
    try expect(match("!*.md", "b.txt"));
    try expect(!match("!*.md", "c.md"));
    // try expect(!match("!**/a.js", "a/a/a.js"));
    // try expect(!match("!**/a.js", "a/b/a.js"));
    // try expect(!match("!**/a.js", "a/c/a.js"));
    try expect(match("!**/a.js", "a/a/b.js"));
    try expect(!match("!a/**/a.js", "a/a/a/a.js"));
    try expect(match("!a/**/a.js", "b/a/b/a.js"));
    try expect(match("!a/**/a.js", "c/a/c/a.js"));
    try expect(match("!**/*.md", "a/b.js"));
    try expect(match("!**/*.md", "a.js"));
    try expect(!match("!**/*.md", "a/b.md"));
    // try expect(!match("!**/*.md", "a.md"));
    try expect(!match("**/*.md", "a/b.js"));
    try expect(!match("**/*.md", "a.js"));
    try expect(match("**/*.md", "a/b.md"));
    try expect(match("**/*.md", "a.md"));
    try expect(match("!**/*.md", "a/b.js"));
    try expect(match("!**/*.md", "a.js"));
    try expect(!match("!**/*.md", "a/b.md"));
    // try expect(!match("!**/*.md", "a.md"));
    try expect(match("!*.md", "a/b.js"));
    try expect(match("!*.md", "a.js"));
    try expect(match("!*.md", "a/b.md"));
    try expect(!match("!*.md", "a.md"));
    try expect(match("!**/*.md", "a.js"));
    // try expect(!match("!**/*.md", "b.md"));
    try expect(match("!**/*.md", "c.txt"));
}

test "question_mark" {
    try expect(match("?", "a"));
    try expect(!match("?", "aa"));
    try expect(!match("?", "ab"));
    try expect(!match("?", "aaa"));
    try expect(!match("?", "abcdefg"));

    try expect(!match("??", "a"));
    try expect(match("??", "aa"));
    try expect(match("??", "ab"));
    try expect(!match("??", "aaa"));
    try expect(!match("??", "abcdefg"));

    try expect(!match("???", "a"));
    try expect(!match("???", "aa"));
    try expect(!match("???", "ab"));
    try expect(match("???", "aaa"));
    try expect(!match("???", "abcdefg"));

    try expect(!match("a?c", "aaa"));
    try expect(match("a?c", "aac"));
    try expect(match("a?c", "abc"));
    try expect(!match("ab?", "a"));
    try expect(!match("ab?", "aa"));
    try expect(!match("ab?", "ab"));
    try expect(!match("ab?", "ac"));
    try expect(!match("ab?", "abcd"));
    try expect(!match("ab?", "abbb"));
    try expect(match("a?b", "acb"));

    try expect(!match("a/?/c/?/e.md", "a/bb/c/dd/e.md"));
    try expect(match("a/??/c/??/e.md", "a/bb/c/dd/e.md"));
    try expect(!match("a/??/c.md", "a/bbb/c.md"));
    try expect(match("a/?/c.md", "a/b/c.md"));
    try expect(match("a/?/c/?/e.md", "a/b/c/d/e.md"));
    try expect(!match("a/?/c/???/e.md", "a/b/c/d/e.md"));
    try expect(match("a/?/c/???/e.md", "a/b/c/zzz/e.md"));
    try expect(!match("a/?/c.md", "a/bb/c.md"));
    try expect(match("a/??/c.md", "a/bb/c.md"));
    try expect(match("a/???/c.md", "a/bbb/c.md"));
    try expect(match("a/????/c.md", "a/bbbb/c.md"));
}

test "braces" {
    try expect(match("{a,b,c}", "a"));
    try expect(match("{a,b,c}", "b"));
    try expect(match("{a,b,c}", "c"));
    try expect(!match("{a,b,c}", "aa"));
    try expect(!match("{a,b,c}", "bb"));
    try expect(!match("{a,b,c}", "cc"));

    try expect(match("a/{a,b}", "a/a"));
    try expect(match("a/{a,b}", "a/b"));
    try expect(!match("a/{a,b}", "a/c"));
    try expect(!match("a/{a,b}", "b/b"));
    try expect(!match("a/{a,b,c}", "b/b"));
    try expect(match("a/{a,b,c}", "a/c"));
    try expect(match("a{b,bc}.txt", "abc.txt"));

    try expect(match("foo[{a,b}]baz", "foo{baz"));

    try expect(!match("a{,b}.txt", "abc.txt"));
    try expect(!match("a{a,b,}.txt", "abc.txt"));
    try expect(!match("a{b,}.txt", "abc.txt"));
    try expect(match("a{,b}.txt", "a.txt"));
    try expect(match("a{b,}.txt", "a.txt"));
    try expect(match("a{a,b,}.txt", "aa.txt"));
    try expect(match("a{a,b,}.txt", "aa.txt"));
    try expect(match("a{,b}.txt", "ab.txt"));
    try expect(match("a{b,}.txt", "ab.txt"));

    // try expect(match("{a/,}a/**", "a"));
    try expect(match("a{a,b/}*.txt", "aa.txt"));
    try expect(match("a{a,b/}*.txt", "ab/.txt"));
    try expect(match("a{a,b/}*.txt", "ab/a.txt"));
    // try expect(match("{a/,}a/**", "a/"));
    try expect(match("{a/,}a/**", "a/a/"));
    // try expect(match("{a/,}a/**", "a/a"));
    try expect(match("{a/,}a/**", "a/a/a"));
    try expect(match("{a/,}a/**", "a/a/"));
    try expect(match("{a/,}a/**", "a/a/a/"));
    try expect(match("{a/,}b/**", "a/b/a/"));
    try expect(match("{a/,}b/**", "b/a/"));
    try expect(match("a{,/}*.txt", "a.txt"));
    try expect(match("a{,/}*.txt", "ab.txt"));
    try expect(match("a{,/}*.txt", "a/b.txt"));
    try expect(match("a{,/}*.txt", "a/ab.txt"));

    try expect(match("a{,.*{foo,db},\\(bar\\)}.txt", "a.txt"));
    try expect(!match("a{,.*{foo,db},\\(bar\\)}.txt", "adb.txt"));
    try expect(match("a{,.*{foo,db},\\(bar\\)}.txt", "a.db.txt"));

    try expect(match("a{,*.{foo,db},\\(bar\\)}.txt", "a.txt"));
    try expect(!match("a{,*.{foo,db},\\(bar\\)}.txt", "adb.txt"));
    try expect(match("a{,*.{foo,db},\\(bar\\)}.txt", "a.db.txt"));

    // try expect(match("a{,.*{foo,db},\\(bar\\)}", "a"));
    try expect(!match("a{,.*{foo,db},\\(bar\\)}", "adb"));
    try expect(match("a{,.*{foo,db},\\(bar\\)}", "a.db"));

    // try expect(match("a{,*.{foo,db},\\(bar\\)}", "a"));
    try expect(!match("a{,*.{foo,db},\\(bar\\)}", "adb"));
    try expect(match("a{,*.{foo,db},\\(bar\\)}", "a.db"));

    try expect(!match("{,.*{foo,db},\\(bar\\)}", "a"));
    try expect(!match("{,.*{foo,db},\\(bar\\)}", "adb"));
    try expect(!match("{,.*{foo,db},\\(bar\\)}", "a.db"));
    try expect(match("{,.*{foo,db},\\(bar\\)}", ".db"));

    try expect(!match("{,*.{foo,db},\\(bar\\)}", "a"));
    try expect(match("{*,*.{foo,db},\\(bar\\)}", "a"));
    try expect(!match("{,*.{foo,db},\\(bar\\)}", "adb"));
    try expect(match("{,*.{foo,db},\\(bar\\)}", "a.db"));

    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/c/xyz.md"));
    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/d/xyz.md"));
    try expect(match("a/b/**/c{d,e}/**/xyz.md", "a/b/cd/xyz.md"));
    try expect(match("a/b/**/{c,d,e}/**/xyz.md", "a/b/c/xyz.md"));
    try expect(match("a/b/**/{c,d,e}/**/xyz.md", "a/b/d/xyz.md"));

    try expect(match("*{a,b}*", "xax"));
    try expect(match("*{a,b}*", "xxax"));
    try expect(match("*{a,b}*", "xbx"));

    try expect(match("*{*a,b}", "xba"));
    try expect(match("*{*a,b}", "xb"));

    try expect(!match("*??", "a"));
    try expect(!match("*???", "aa"));
    try expect(match("*???", "aaa"));
    try expect(!match("*****??", "a"));
    try expect(!match("*****???", "aa"));
    try expect(match("*****???", "aaa"));

    try expect(!match("a*?c", "aaa"));
    try expect(match("a*?c", "aac"));
    try expect(match("a*?c", "abc"));

    try expect(match("a**?c", "abc"));
    try expect(!match("a**?c", "abb"));
    try expect(match("a**?c", "acc"));
    try expect(match("a*****?c", "abc"));

    try expect(match("*****?", "a"));
    try expect(match("*****?", "aa"));
    try expect(match("*****?", "abc"));
    try expect(match("*****?", "zzz"));
    try expect(match("*****?", "bbb"));
    try expect(match("*****?", "aaaa"));

    try expect(!match("*****??", "a"));
    try expect(match("*****??", "aa"));
    try expect(match("*****??", "abc"));
    try expect(match("*****??", "zzz"));
    try expect(match("*****??", "bbb"));
    try expect(match("*****??", "aaaa"));

    try expect(!match("?*****??", "a"));
    try expect(!match("?*****??", "aa"));
    try expect(match("?*****??", "abc"));
    try expect(match("?*****??", "zzz"));
    try expect(match("?*****??", "bbb"));
    try expect(match("?*****??", "aaaa"));

    try expect(match("?*****?c", "abc"));
    try expect(!match("?*****?c", "abb"));
    try expect(!match("?*****?c", "zzz"));

    try expect(match("?***?****c", "abc"));
    try expect(!match("?***?****c", "bbb"));
    try expect(!match("?***?****c", "zzz"));

    try expect(match("?***?****?", "abc"));
    try expect(match("?***?****?", "bbb"));
    try expect(match("?***?****?", "zzz"));

    try expect(match("?***?****", "abc"));
    try expect(match("*******c", "abc"));
    try expect(match("*******?", "abc"));
    try expect(match("a*cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k***", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k**", "abcdecdhjk"));
    try expect(match("a****c**?**??*****", "abcdecdhjk"));

    try expect(!match("a/?/c/?/*/e.md", "a/b/c/d/e.md"));
    try expect(match("a/?/c/?/*/e.md", "a/b/c/d/e/e.md"));
    try expect(match("a/?/c/?/*/e.md", "a/b/c/d/efghijk/e.md"));
    try expect(match("a/?/**/e.md", "a/b/c/d/efghijk/e.md"));
    try expect(!match("a/?/e.md", "a/bb/e.md"));
    try expect(match("a/??/e.md", "a/bb/e.md"));
    try expect(!match("a/?/**/e.md", "a/bb/e.md"));
    try expect(match("a/?/**/e.md", "a/b/ccc/e.md"));
    try expect(match("a/*/?/**/e.md", "a/b/c/d/efghijk/e.md"));
    try expect(match("a/*/?/**/e.md", "a/b/c/d/efgh.ijk/e.md"));
    try expect(match("a/*/?/**/e.md", "a/b.bb/c/d/efgh.ijk/e.md"));
    try expect(match("a/*/?/**/e.md", "a/bbb/c/d/efgh.ijk/e.md"));

    try expect(match("a/*/ab??.md", "a/bbb/abcd.md"));
    try expect(match("a/bbb/ab??.md", "a/bbb/abcd.md"));
    try expect(match("a/bbb/ab???md", "a/bbb/abcd.md"));
}

fn matchSame(str: []const u8) bool {
    return match(str, str);
}
test "fuzz_tests" {
    // https://github.com/devongovett/glob-match/issues/1
    try expect(!matchSame(
        "{*{??*{??**,Uz*zz}w**{*{**a,z***b*[!}w??*azzzzzzzz*!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!z[za,z&zz}w**z*z*}",
    ));
    try expect(!matchSame(
        "**** *{*{??*{??***\x05 *{*{??*{??***0x5,\x00U\x00}]*****0x1,\x00***\x00,\x00\x00}w****,\x00U\x00}]*****0x1,\x00***\x00,\x00\x00}w*****0x1***{}*.*\x00\x00*\x00",
    ));
}
