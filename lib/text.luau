--!strict
-- Controlled text fields. Tern draws a field from `text`, `cursor` and `anchor`, all in UTF-16 code
-- units, while Luau strings are UTF-8 bytes; every offset conversion lives here.

local types = require("./types")

type Field = types.Field

export type Key = {
	name: string,
	text: string?,
	ctrl: boolean,
	alt: boolean,
	shift: boolean,
	meta: boolean,
}

local text = {}

-- ─── UTF-16 helpers ─────────────────────────────────────────────────────────

local function width(codepoint: number): number
	return if codepoint > 0xFFFF then 2 else 1
end

function text.len16(s: string): number
	local n = 0
	for _, cp in utf8.codes(s) do
		n += width(cp)
	end
	return n
end

-- Byte index of the code point that starts at UTF-16 offset `units`; #s + 1 past the end.
-- An offset inside a surrogate pair resolves to the pair's start.
local function byteAt(s: string, units: number): number
	local acc = 0
	for pos, cp in utf8.codes(s) do
		local w = width(cp)
		if acc + w > units then
			return pos
		end
		acc += w
	end
	return #s + 1
end

local function splice16(s: string, from: number, to: number, insert: string): string
	return string.sub(s, 1, byteAt(s, from) - 1) .. insert .. string.sub(s, byteAt(s, to))
end

-- Start of the code point before `units`.
local function previousBoundary(s: string, units: number): number
	local previous, acc = 0, 0
	for _, cp in utf8.codes(s) do
		if acc >= units then
			break
		end
		previous = acc
		acc += width(cp)
	end
	return previous
end

-- End of the code point at (or containing) `units`.
local function nextBoundary(s: string, units: number): number
	local acc = 0
	for _, cp in utf8.codes(s) do
		acc += width(cp)
		if acc > units then
			return acc
		end
	end
	return acc
end

type Unit = { cp: number, from: number, to: number }

local function scan(s: string): { Unit }
	local out: { Unit } = {}
	local acc = 0
	for _, cp in utf8.codes(s) do
		local w = width(cp)
		table.insert(out, { cp = cp, from = acc, to = acc + w })
		acc += w
	end
	return out
end

local NEWLINE = 10

local function lineStart(s: string, units: number): number
	local start = 0
	for _, u in scan(s) do
		if u.from >= units then
			break
		end
		if u.cp == NEWLINE then
			start = u.to
		end
	end
	return start
end

local function lineEnd(s: string, units: number): number
	for _, u in scan(s) do
		if u.from >= units and u.cp == NEWLINE then
			return u.from
		end
	end
	return text.len16(s)
end

local function isWordChar(cp: number): boolean
	if cp < 0x80 then
		return (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) or cp == 95
	end
	-- Non-ASCII: letters and digits of other scripts count; NBSP, general punctuation and CJK spaces do not.
	return cp ~= 0xA0 and not (cp >= 0x2000 and cp <= 0x206F) and cp ~= 0x3000
end

local function wordLeft(s: string, units: number): number
	local list = scan(s)
	local i = #list
	while i > 0 and list[i].from >= units do
		i -= 1
	end
	while i > 0 and not isWordChar(list[i].cp) do
		i -= 1
	end
	while i > 0 and isWordChar(list[i].cp) do
		i -= 1
	end
	return if i == 0 then 0 else list[i].to
end

local function wordRight(s: string, units: number): number
	local list = scan(s)
	local n = #list
	local i = 1
	while i <= n and list[i].to <= units do
		i += 1
	end
	while i <= n and not isWordChar(list[i].cp) do
		i += 1
	end
	while i <= n and isWordChar(list[i].cp) do
		i += 1
	end
	if i > n then
		return if n == 0 then 0 else list[n].to
	end
	return list[i].from
end

-- ─── Field operations ───────────────────────────────────────────────────────

local function clamp(value: number, low: number, high: number): number
	return math.max(low, math.min(high, value))
end

function text.new(s: string?): Field
	local value = s or ""
	return { text = value, cursor = text.len16(value), anchor = nil }
end

function text.set(f: Field, s: string)
	f.text = s
	f.cursor = text.len16(s)
	f.anchor = nil
end

function text.trimmed(f: Field): string
	return (string.match(f.text, "^%s*(.-)%s*$")) :: string
end

-- Selected range as (low, high), or nil when nothing is selected.
local function selection(f: Field): (number?, number?)
	local anchor = f.anchor
	if anchor == nil or anchor == f.cursor then
		return nil, nil
	end
	return math.min(anchor, f.cursor), math.max(anchor, f.cursor)
end

local function replaceRange(f: Field, from: number, to: number, insert: string)
	f.text = splice16(f.text, from, to, insert)
	f.cursor = from + text.len16(insert)
	f.anchor = nil
end

local function insert(f: Field, s: string)
	local low, high = selection(f)
	local at = clamp(f.cursor, 0, text.len16(f.text))
	replaceRange(f, low or at, high or at, s)
end

-- Removes the selection if there is one, otherwise from..to.
local function deleteRange(f: Field, from: number, to: number)
	local low, high = selection(f)
	if low ~= nil and high ~= nil then
		replaceRange(f, low, high, "")
	elseif from < to then
		replaceRange(f, from, to, "")
	end
end

local function moveCursor(f: Field, target: number, extend: boolean)
	if extend then
		if f.anchor == nil then
			f.anchor = f.cursor
		end
	else
		f.anchor = nil
	end
	f.cursor = target
end

local function pasteText(s: string, multiline: boolean): string
	local normalized = string.gsub(s, "\r\n?", "\n")
	if multiline then
		return normalized
	end
	return (string.gsub(normalized, "\n", " "))
end

local function hasControlBytes(s: string): boolean
	return string.find(s, "%c") ~= nil
end

local function handleBackspace(f: Field, key: Key)
	local cursor = clamp(f.cursor, 0, text.len16(f.text))
	local from = previousBoundary(f.text, cursor)
	if key.ctrl or key.meta then
		local start = lineStart(f.text, cursor)
		from = if start < cursor then start else from
	elseif key.alt then
		from = wordLeft(f.text, cursor)
	end
	deleteRange(f, from, cursor)
end

-- Returns the cursor target for a navigation key, or nil when `key` is not one.
local function navigationTarget(f: Field, key: Key): number?
	local len = text.len16(f.text)
	local cursor = clamp(f.cursor, 0, len)
	local low, high = selection(f)
	local name = key.name
	local byWord = key.alt or key.ctrl
	if name == "left" then
		if key.meta then
			return lineStart(f.text, cursor)
		elseif byWord then
			return wordLeft(f.text, cursor)
		elseif low ~= nil and not key.shift then
			return low
		end
		return previousBoundary(f.text, cursor)
	elseif name == "right" then
		if key.meta then
			return lineEnd(f.text, cursor)
		elseif byWord then
			return wordRight(f.text, cursor)
		elseif high ~= nil and not key.shift then
			return high
		end
		return nextBoundary(f.text, cursor)
	elseif name == "home" then
		return lineStart(f.text, cursor)
	elseif name == "end" then
		return lineEnd(f.text, cursor)
	end
	return nil
end

function text.key(f: Field, key: Key, multiline: boolean): boolean
	local name = key.name
	local command = key.ctrl or key.meta
	f.cursor = clamp(f.cursor, 0, text.len16(f.text))

	if name == "paste" then
		insert(f, pasteText(key.text or "", multiline))
		return true
	end
	if command and name == "a" then
		f.anchor = 0
		f.cursor = text.len16(f.text)
		return true
	end
	if name == "backspace" then
		handleBackspace(f, key)
		return true
	end
	if name == "delete" then
		deleteRange(f, f.cursor, nextBoundary(f.text, f.cursor))
		return true
	end
	local target = navigationTarget(f, key)
	if target ~= nil then
		moveCursor(f, clamp(target, 0, text.len16(f.text)), key.shift)
		return true
	end
	if name == "enter" then
		if multiline and not (command or key.alt or key.shift) then
			insert(f, "\n")
			return true
		end
		return false
	end
	local typed = key.text
	if typed ~= nil and typed ~= "" and not command and not hasControlBytes(typed) then
		insert(f, typed)
		return true
	end
	return false
end

-- Applies Tern's native `edit` event: replace from..to with `text`, caret at `cursor`. Ignored when the
-- event was computed against a different text (`len` mismatch), i.e. when it is stale.
function text.applyEdit(f: Field, ev: { [string]: any }): boolean
	local from, to, inserted, len = ev.from, ev.to, ev.text, ev.len
	if type(from) ~= "number" or type(to) ~= "number" or type(inserted) ~= "string" or type(len) ~= "number" then
		return false
	end
	if len ~= text.len16(f.text) then
		return false
	end
	local low = clamp(math.min(from, to), 0, len)
	local high = clamp(math.max(from, to), 0, len)
	f.text = splice16(f.text, low, high, inserted)
	local newLen = text.len16(f.text)
	local cursor = ev.cursor
	f.cursor = clamp(if type(cursor) == "number" then cursor else low + text.len16(inserted), 0, newLen)
	f.anchor = nil
	return true
end

return text
