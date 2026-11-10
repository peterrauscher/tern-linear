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

-- ─── Markdown sanitising ────────────────────────────────────────────────────

local BYTE_BACKSLASH, BYTE_BACKTICK, BYTE_BANG, BYTE_LT, BYTE_LBRACKET, BYTE_RBRACKET, BYTE_LPAREN, BYTE_RPAREN =
	92, 96, 33, 60, 91, 93, 40, 41

type Tail = { text: string, resume: number }

-- Only web and mail targets may stay clickable: https?:// and mailto: (case-insensitive).
local function allowedTarget(url: string): boolean
	local head = string.lower(string.sub(url, 1, 8))
	return string.sub(head, 1, 7) == "http://" or head == "https://" or string.sub(head, 1, 7) == "mailto:"
end

-- Inline code spans per line (a span never crosses a line here, so an unpaired backtick can only make
-- the scanner see less code, never hide a link). Returns start byte -> end byte, inclusive.
local function codeSpans(p: string): { [number]: number }
	local spans: { [number]: number } = {}
	local n = #p
	local lineStart = 1
	while lineStart <= n do
		local lineEnd = string.find(p, "\n", lineStart, true) or (n + 1)
		local line = string.sub(p, lineStart, lineEnd - 1)
		if string.find(line, "`", 1, true) ~= nil then
			local offset = lineStart - 1
			local starts: { number } = {}
			local lengths: { number } = {}
			local escaped: { boolean } = {}
			local pos = 1
			while true do
				local a, b = string.find(line, "`+", pos)
				if a == nil or b == nil then
					break
				end
				local slashes = 0
				while a - slashes > 1 and string.byte(line, a - slashes - 1) == BYTE_BACKSLASH do
					slashes += 1
				end
				table.insert(starts, a + offset)
				table.insert(lengths, b - a + 1)
				table.insert(escaped, slashes % 2 == 1)
				pos = b + 1
			end
			-- The closer of a run is the next run of the same length.
			local count = #starts
			local nextSame: { number } = {}
			local lastOfLength: { [number]: number } = {}
			for k = count, 1, -1 do
				local len = lengths[k]
				nextSame[k] = lastOfLength[len] or 0
				lastOfLength[len] = k
			end
			local k = 1
			while k <= count do
				local closer = nextSame[k]
				if closer > 0 and not escaped[k] then
					spans[starts[k]] = starts[closer] + lengths[closer] - 1
					k = closer + 1
				else
					k += 1
				end
			end
		end
		lineStart = lineEnd + 1
	end
	return spans
end

-- Balanced matches for one bracket pair, skipping escapes (and code spans when `spans` is given).
local function matchPairs(
	p: string,
	open: number,
	close: number,
	pattern: string,
	spans: { [number]: number }?
): { [number]: number }
	local match: { [number]: number } = {}
	local stack: { number } = {}
	local pos = 1
	while true do
		local a = string.find(p, pattern, pos)
		if a == nil then
			break
		end
		local c = string.byte(p, a)
		pos = a + 1
		if c == BYTE_BACKSLASH then
			pos = a + 2
		elseif c == BYTE_BACKTICK then
			local e = if spans ~= nil then spans[a] else nil
			if e ~= nil then
				pos = e + 1
			end
		elseif c == open then
			table.insert(stack, a)
		elseif c == close then
			local top = table.remove(stack)
			if top ~= nil then
				match[top] = a
			end
		end
	end
	return match
end

local function isSpaceByte(c: number): boolean
	return c == 32 or (c >= 9 and c <= 13)
end

type Inline = {
	p: string,
	parens: { [number]: number },
	nextSpace: { number },
}

-- Parses the `(dest "title")` that follows the `]` at `closeBracket`. Returns the raw destination as
-- written (with any <>), the destination to check, and the position of the final `)`.
local function parseDestination(ctx: Inline, closeBracket: number): (string?, string?, number?)
	local p = ctx.p
	local open = closeBracket + 1
	local s = string.find(p, "%S", open + 1)
	if s == nil then
		return nil, nil, nil
	end
	if string.byte(p, s) == BYTE_LT then
		local g = string.find(p, ">", s + 1, true)
		if g == nil then
			return nil, nil, nil
		end
		local inner = string.sub(p, s + 1, g - 1)
		if string.find(inner, "[\n<]") ~= nil then
			return nil, nil, nil
		end
		local nxt = string.find(p, "%S", g + 1)
		if nxt == nil then
			return nil, nil, nil
		end
		local c = string.byte(p, nxt)
		if c == BYTE_RPAREN then
			return string.sub(p, s, g), inner, nxt
		end
		local delimiter = if c == 34 then '"' elseif c == 39 then "'" elseif c == BYTE_LPAREN then ")" else nil
		if delimiter == nil then
			return nil, nil, nil
		end
		local titleEnd = string.find(p, delimiter, nxt + 1, true)
		if titleEnd == nil then
			return nil, nil, nil
		end
		local last = string.find(p, "%S", titleEnd + 1)
		if last == nil or string.byte(p, last) ~= BYTE_RPAREN then
			return nil, nil, nil
		end
		return string.sub(p, s, g), inner, last
	end
	local close = ctx.parens[open]
	if close == nil then
		return nil, nil, nil
	end
	if s >= close then
		return "", "", close
	end
	local stop = math.min(ctx.nextSpace[s], close)
	local dest = string.sub(p, s, stop - 1)
	return dest, dest, close
end

-- One block of text outside code fences: rewrites images and links that could be dangerous.
local function sanitiseInline(p: string): string
	local n = #p
	local spans = codeSpans(p)
	local brackets = matchPairs(p, BYTE_LBRACKET, BYTE_RBRACKET, "[%[%]\\`]", spans)
	local ctx: Inline = { p = p, parens = {}, nextSpace = {} }
	if string.find(p, "](", 1, true) ~= nil then
		ctx.parens = matchPairs(p, BYTE_LPAREN, BYTE_RPAREN, "[()\\]", nil)
		local following = n + 1
		for i = n, 1, -1 do
			if isSpaceByte(string.byte(p, i)) then
				following = i
			end
			ctx.nextSpace[i] = following
		end
	end

	local out: { string } = {}
	local tails: { [number]: Tail } = {}
	local pos = 1
	while pos <= n do
		local a = string.find(p, "[%[%]\\`!<]", pos)
		if a == nil then
			table.insert(out, string.sub(p, pos))
			break
		end
		if a > pos then
			table.insert(out, string.sub(p, pos, a - 1))
		end
		local c = string.byte(p, a)
		pos = a + 1
		if c == BYTE_BACKSLASH then
			table.insert(out, string.sub(p, a, a + 1))
			pos = a + 2
		elseif c == BYTE_BACKTICK then
			local e = spans[a]
			if e ~= nil then
				table.insert(out, string.sub(p, a, e))
				pos = e + 1
			else
				table.insert(out, "`")
			end
		elseif c == BYTE_RBRACKET then
			local tail = tails[a]
			if tail ~= nil then
				table.insert(out, tail.text)
				pos = tail.resume
			else
				table.insert(out, "]")
			end
		elseif c == BYTE_LBRACKET or (c == BYTE_BANG and string.byte(p, a + 1) == BYTE_LBRACKET) then
			local isImage = c == BYTE_BANG
			local open = if isImage then a + 1 else a
			local close = brackets[open]
			local raw: string?, target: string?, paren: number? = nil, nil, nil
			if close ~= nil and string.byte(p, close + 1) == BYTE_LPAREN then
				raw, target, paren = parseDestination(ctx, close)
			end
			if close == nil then
				table.insert(out, string.sub(p, a, open))
				pos = open + 1
			elseif raw == nil or target == nil or paren == nil then
				-- Not an inline link: a reference image only loses its `!`.
				table.insert(out, "[")
				pos = open + 1
			else
				local keep = allowedTarget(target)
				local blank = string.find(string.sub(p, open + 1, close - 1), "%S") == nil
				if isImage then
					table.insert(out, if keep then "[🖼 " else "🖼 ")
					if blank then
						table.insert(out, "Image")
					end
					tails[close] = { text = if keep then "](" .. raw .. ")" else "", resume = paren + 1 }
				else
					if keep then
						table.insert(out, "[")
					end
					tails[close] = { text = if keep then string.sub(p, close, paren) else "", resume = paren + 1 }
				end
				pos = open + 1
			end
		elseif c == BYTE_BANG then
			table.insert(out, "!")
		else -- "<"
			local whole, scheme = string.match(p, "^(<([%a][%w%+%.%-]*):[^%s<>]*>)", a)
			if whole == nil or scheme == nil then
				table.insert(out, "<")
			else
				local lowered = string.lower(scheme)
				if lowered == "http" or lowered == "https" or lowered == "mailto" then
					table.insert(out, whole)
				else
					table.insert(out, string.sub(whole, 2, #whole - 1))
				end
				pos = a + #whole
			end
		end
	end
	return table.concat(out)
end

-- The destination of a `[label]: url "title"` line, or nil when `line` is not one. `rest` is what
-- follows the colon; an empty `rest` means the destination is on the next line.
local function definitionLabel(line: string): string?
	local label, rest = string.match(line, "^ ? ? ?%[([^%]]+)%]:[ \t]*(.-)[ \t\r]*$")
	if label == nil or rest == nil or string.sub(label, 1, 1) == "^" then
		return nil
	end
	return rest
end

local function definitionTarget(rest: string): (string?, boolean)
	local url: string?, after: string?
	if string.sub(rest, 1, 1) == "<" then
		local inner, tail = string.match(rest, "^<([^>]*)>(.*)$")
		url, after = inner, tail
	else
		local token, tail = string.match(rest, "^(%S+)(.*)$")
		url, after = token, tail
	end
	if url == nil or after == nil then
		return nil, false
	end
	local title = string.match(after, "^%s*(.-)%s*$") :: string
	if title ~= "" then
		local opener, closer = string.sub(title, 1, 1), string.sub(title, -1)
		local wrapped = #title >= 2
			and (opener == closer and (opener == '"' or opener == "'") or (opener == "(" and closer == ")"))
		if not wrapped then
			return nil, false
		end
	end
	return url, true
end

-- Makes untrusted Markdown safe to render: images become links, and link, autolink and reference
-- definition targets other than https?:// and mailto: are removed (the link keeps its label text;
-- a definition line is dropped). Fenced code blocks and inline code spans are left untouched, as is
-- all other text. Linear in the input size.
function text.safeMarkdown(s: string): string
	if string.find(s, "[%[<]") == nil then
		return s
	end
	local out: { string } = {}
	local n = #s
	local paragraph: number? = nil
	local fenceChar: string? = nil
	local fenceLen = 0

	local function flush(upTo: number)
		local start = paragraph
		if start ~= nil then
			table.insert(out, sanitiseInline(string.sub(s, start, upTo)))
			paragraph = nil
		end
	end

	local pos = 1
	while pos <= n do
		local newline = string.find(s, "\n", pos, true)
		local lineEnd = newline or n
		local line = string.sub(s, pos, (newline or (n + 1)) - 1)
		local full = string.sub(s, pos, lineEnd)
		local nextPos = lineEnd + 1
		if fenceChar ~= nil then
			table.insert(out, full)
			local run = string.match(line, "^ ? ? ?(" .. fenceChar .. "+)%s*$")
			if run ~= nil and #run >= fenceLen then
				fenceChar = nil
			end
		else
			local ticks = string.match(line, "^ ? ? ?(```+)[^`]*$")
			local tildes = string.match(line, "^ ? ? ?(~~~+)")
			if ticks ~= nil or tildes ~= nil then
				flush(pos - 1)
				table.insert(out, full)
				local marker = (ticks or tildes) :: string
				fenceChar = string.sub(marker, 1, 1)
				fenceLen = #marker
			elseif string.find(line, "%S") == nil then
				flush(pos - 1)
				table.insert(out, full)
			else
				local rest = definitionLabel(line)
				local url: string?, isDefinition: boolean = nil, false
				local definitionEnd = lineEnd
				if rest ~= nil then
					if rest == "" and nextPos <= n then
						local nextNewline = string.find(s, "\n", nextPos, true)
						local nextLine = string.sub(s, nextPos, (nextNewline or (n + 1)) - 1)
						url, isDefinition = definitionTarget(string.match(nextLine, "^%s*(.-)%s*$") :: string)
						definitionEnd = nextNewline or n
					else
						url, isDefinition = definitionTarget(rest)
					end
				end
				if isDefinition and url ~= nil then
					flush(pos - 1)
					if allowedTarget(url) then
						table.insert(out, string.sub(s, pos, definitionEnd))
					end
					nextPos = definitionEnd + 1
				elseif paragraph == nil then
					paragraph = pos
				end
			end
		end
		pos = nextPos
	end
	flush(n)
	return table.concat(out)
end

return text
