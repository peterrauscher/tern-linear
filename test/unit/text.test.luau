--!strict
-- Unit tests for lib/text.luau: UTF-16 editing over UTF-8 strings. Run with the `luau` CLI.

local text = require("../../lib/text")
local types = require("../../lib/types")

local failures = 0

local function check(name: string, condition: boolean)
	if condition then
		print("ok   " .. name)
	else
		failures += 1
		print("FAIL " .. name)
	end
end

local EMOJI = "😀" -- U+1F600: 4 UTF-8 bytes, 2 UTF-16 units

type Mods = { shift: boolean?, ctrl: boolean?, alt: boolean?, meta: boolean? }

local function press(name: string, mods: Mods?): text.Key
	local m: Mods = mods or {}
	return {
		name = name,
		text = nil,
		ctrl = m.ctrl == true,
		alt = m.alt == true,
		shift = m.shift == true,
		meta = m.meta == true,
	}
end

local function typed(char: string): text.Key
	return { name = char, text = char, ctrl = false, alt = false, shift = false, meta = false }
end

local function field(s: string, cursor: number?, anchor: number?): types.Field
	return { text = s, cursor = cursor or text.len16(s), anchor = anchor }
end

-- ─── lengths and construction ───────────────────────────────────────────────

check("len16 counts astral characters twice", text.len16("a" .. EMOJI .. "б") == 4)
check("len16 of empty string", text.len16("") == 0)

local created = text.new("a" .. EMOJI)
check("new puts the cursor at the end in UTF-16 units", created.cursor == 3 and created.anchor == nil)

local reset = field("old", 1, 0)
text.set(reset, "новый")
check(
	"set moves the cursor to the end and clears the anchor",
	reset.text == "новый" and reset.cursor == 5 and reset.anchor == nil
)
check("trimmed strips surrounding whitespace", text.trimmed(field("  hi there \n")) == "hi there")

-- ─── typing ─────────────────────────────────────────────────────────────────

local f = field("")
check("typing an emoji is handled", text.key(f, typed(EMOJI), false))
check("emoji advances the cursor by two units", f.text == EMOJI and f.cursor == 2)
text.key(f, typed("x"), false)
check("typing after an emoji appends", f.text == EMOJI .. "x" and f.cursor == 3)

f = field("ab", 1)
text.key(f, typed("Ж"), false)
check("typing Cyrillic inserts at the cursor", f.text == "aЖb" and f.cursor == 2)

f = field("a")
check(
	"ctrl+letter is not text",
	not text.key(f, { name = "x", text = "x", ctrl = true, alt = false, shift = false, meta = false }, false)
)
check(
	"an altered composed character is inserted",
	text.key(f, { name = "e", text = "é", ctrl = false, alt = true, shift = false, meta = false }, false)
		and f.text == "aé"
)
check(
	"tab is not text",
	not text.key(f, { name = "tab", text = "\t", ctrl = false, alt = false, shift = false, meta = false }, false)
)

-- ─── backspace and delete ───────────────────────────────────────────────────

f = field("a" .. EMOJI)
text.key(f, press("backspace"), false)
check("backspace removes a whole astral code point", f.text == "a" and f.cursor == 1)

f = field("привет")
text.key(f, press("backspace"), false)
check("backspace removes one Cyrillic letter", f.text == "приве" and f.cursor == 5)

f = field(EMOJI .. "b", 0)
text.key(f, press("delete"), false)
check("delete removes the astral code point after the cursor", f.text == "b" and f.cursor == 0)

f = field("ab")
check("delete at the end does nothing but is handled", text.key(f, press("delete"), false) and f.text == "ab")

f = field("hello", 5, 1)
text.key(f, press("backspace"), false)
check("backspace deletes the selection", f.text == "h" and f.cursor == 1 and f.anchor == nil)

f = field("ab\ncd", 5)
text.key(f, press("backspace", { meta = true }), true)
check("cmd+backspace deletes to the line start", f.text == "ab\n" and f.cursor == 3)

f = field("foo bar", 7)
text.key(f, press("backspace", { alt = true }), false)
check("alt+backspace deletes the previous word", f.text == "foo " and f.cursor == 4)

-- ─── selection and replacement ──────────────────────────────────────────────

f = field("hello")
text.key(f, press("left", { shift = true }), false)
text.key(f, press("left", { shift = true }), false)
check("shift+left extends the selection", f.anchor == 5 and f.cursor == 3)
text.key(f, typed("y"), false)
check("typing replaces the selection", f.text == "hely" and f.cursor == 4 and f.anchor == nil)

f = field("a" .. EMOJI .. "b", 3)
text.key(f, press("left", { shift = true }), false)
check("shift+left selects a whole astral code point", f.anchor == 3 and f.cursor == 1)
text.key(f, typed("-"), false)
check("replacing a selection that spans an emoji", f.text == "a-b" and f.cursor == 2 and f.anchor == nil)

f = field("abc")
text.key(f, press("a", { meta = true }), false)
check("cmd+a selects everything", f.anchor == 0 and f.cursor == 3)
text.key(f, typed("z"), false)
check("typing over select-all replaces the text", f.text == "z")

f = field("abc", 2, 0)
text.key(f, press("left"), false)
check("left collapses a selection to its start", f.cursor == 0 and f.anchor == nil)

f = field("abc", 1, 3)
text.key(f, press("right"), false)
check("right collapses a selection to its end", f.cursor == 3 and f.anchor == nil)

-- ─── movement ───────────────────────────────────────────────────────────────

f = field(EMOJI .. "x", 2)
text.key(f, press("left"), false)
check("left steps over an emoji in one move", f.cursor == 0)
text.key(f, press("right"), false)
check("right steps over an emoji in one move", f.cursor == 2)

f = field("one two", 7)
text.key(f, press("left", { alt = true }), false)
check("alt+left jumps to the word start", f.cursor == 4)
text.key(f, press("left", { alt = true }), false)
check("alt+left jumps again", f.cursor == 0)
text.key(f, press("right", { alt = true }), false)
check("alt+right jumps to the word end", f.cursor == 3)

f = field("привет мир", 0)
text.key(f, press("right", { alt = true }), false)
check("word moves treat Cyrillic as word characters", f.cursor == 6)

f = field("ab\ncd", 4)
text.key(f, press("home"), true)
check("home goes to the line start in multiline text", f.cursor == 3)
text.key(f, press("end"), true)
check("end goes to the line end in multiline text", f.cursor == 5)
text.key(f, press("home", { shift = true }), true)
check("shift+home selects to the line start", f.anchor == 5 and f.cursor == 3)

f = field("abc", 1)
check("up is not used", not text.key(f, press("up"), false))

-- ─── paste and enter ────────────────────────────────────────────────────────

f = field("x")
text.key(f, { name = "paste", text = "a\nb\r\nc", ctrl = false, alt = false, shift = false, meta = false }, false)
check("single-line paste turns newlines into spaces", f.text == "xa b c" and f.cursor == 6)

f = field("x")
text.key(f, { name = "paste", text = "a\r\nb", ctrl = false, alt = false, shift = false, meta = false }, true)
check("multiline paste keeps newlines", f.text == "xa\nb")

f = field("x", 0, 1)
text.key(f, { name = "paste", text = EMOJI, ctrl = false, alt = false, shift = false, meta = false }, false)
check("paste replaces the selection", f.text == EMOJI and f.cursor == 2)

f = field("a")
check("enter inserts a newline in multiline fields", text.key(f, press("enter"), true) and f.text == "a\n")
check("enter is not used in single-line fields", not text.key(f, press("enter"), false))
check("shift+enter is not used in multiline fields", not text.key(f, press("enter", { shift = true }), true))
check("ctrl+enter is not used in multiline fields", not text.key(f, press("enter", { ctrl = true }), true))

-- ─── native edit events ─────────────────────────────────────────────────────

f = field(EMOJI .. "ab", 4)
local applied = text.applyEdit(f, { ev = "edit", id = "main.f", from = 2, to = 3, text = "X", cursor = 3, len = 4 })
check("applyEdit splices in UTF-16 offsets", applied and f.text == EMOJI .. "Xb" and f.cursor == 3 and f.anchor == nil)

f = field("abc", 3, 0)
text.applyEdit(f, { ev = "edit", id = "main.f", from = 1, to = 1, text = "", cursor = 1, len = 3 })
check("applyEdit moves the caret and clears the anchor", f.text == "abc" and f.cursor == 1 and f.anchor == nil)

f = field(EMOJI .. "ab")
check(
	"applyEdit ignores an event computed against another text",
	not text.applyEdit(f, { ev = "edit", id = "main.f", from = 0, to = 0, text = "Z", cursor = 1, len = 3 })
		and f.text == EMOJI .. "ab"
)

f = field("привет", 6)
text.applyEdit(f, { ev = "edit", id = "main.f", from = 0, to = 6, text = "ok", cursor = 2, len = 6 })
check("applyEdit replaces Cyrillic text", f.text == "ok" and f.cursor == 2)

if failures > 0 then
	error(`{failures} text test(s) failed`)
end
print("text tests passed")
