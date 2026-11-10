--!strict
-- API key resolution and storage. The host half cannot reach tern.secrets (window-only), so a
-- stored key lives in `<plugin data>/credentials.json`, created owner-only (file 600, directory 700)
-- on POSIX. Nothing here logs, displays or returns the key except resolve(), and resolve() withholds
-- it when LINEAR_API_URL points anywhere but Linear or this machine.

local types = require("./types")

local credentials = {}

local DEFAULT_ENDPOINT = "https://api.linear.app/graphql"
local KEY_PREFIXES = { "lin_api_", "lin_oauth_" }
local MAX_KEY_FILE_BYTES = 16384

local function keyFilePath(): string
	return tern.plugin.data .. "/credentials.json"
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) or ""
end

local function nonEmpty(s: string?): string?
	if s == nil then
		return nil
	end
	local trimmed = trim(s)
	if trimmed == "" then
		return nil
	end
	return trimmed
end

local function envKey(): string?
	return nonEmpty(tern.getenv("LINEAR_API_KEY"))
end

-- A missing, unreadable or corrupt file all mean "no key".
local function fileKey(): string?
	local path = keyFilePath()
	local existsOk, exists = pcall(tern.fs.exists, path)
	if not existsOk or not exists then
		return nil
	end
	local readOk, raw = pcall(tern.fs.read, path, MAX_KEY_FILE_BYTES)
	if not readOk then
		return nil
	end
	local decodeOk, doc = pcall(tern.json.decode, raw)
	if not decodeOk or type(doc) ~= "table" then
		return nil
	end
	local key = doc.apiKey
	if type(key) ~= "string" then
		return nil
	end
	return nonEmpty(key)
end

local ENDPOINT_REJECTED = "LINEAR_API_URL is not an allowed endpoint, so the API key was not sent. "
	.. "Use https://api.linear.app/graphql or a local http(s) address (127.0.0.1, localhost or [::1])."

local LOCAL_HOSTS = { ["127.0.0.1"] = true, ["localhost"] = true, ["[::1]"] = true }

local function allowedEndpoint(url: string): boolean
	if url == DEFAULT_ENDPOINT then
		return true
	end
	if string.find(url, "[%s%c\\]") ~= nil then
		return false
	end
	local scheme, authority = string.match(url, "^(%a+)://([^/?#]*)")
	if scheme == nil or authority == nil then
		return false
	end
	scheme = string.lower(scheme)
	if scheme ~= "http" and scheme ~= "https" then
		return false
	end
	-- No userinfo (`localhost@evil.example`), and an optional all-digit port after the host.
	if string.find(authority, "@", 1, true) ~= nil then
		return false
	end
	local host, port = string.match(authority, "^(%[[%x:]+%])(.*)$")
	if host == nil then
		host, port = string.match(authority, "^([^:]*)(.*)$")
	end
	if host == nil or port == nil or LOCAL_HOSTS[string.lower(host)] ~= true then
		return false
	end
	return port == "" or string.match(port, "^:%d+$") ~= nil
end

-- The endpoint requests go to: `LINEAR_API_URL` when set, else Linear's API. Only
-- https://api.linear.app/graphql and http(s) on 127.0.0.1, localhost or [::1] are allowed, so a
-- hostile environment cannot redirect the key elsewhere. A rejected value returns nil and a
-- user-safe message (it does not echo the value).
function credentials.endpoint(): (string?, string?)
	local url = nonEmpty(tern.getenv("LINEAR_API_URL"))
	if url == nil then
		return DEFAULT_ENDPOINT, nil
	end
	if not allowedEndpoint(url) then
		return nil, ENDPOINT_REJECTED
	end
	return url, nil
end

-- The key (environment first, then the stored file) with its endpoint, or nil when there is no key.
-- A key with a rejected endpoint resolves to nil plus the reason: the key is never handed out for it.
function credentials.resolve(): (types.Config?, string?)
	local key = envKey() or fileKey()
	if key == nil then
		return nil, nil
	end
	local endpoint, rejected = credentials.endpoint()
	if endpoint == nil then
		return nil, rejected
	end
	return { key = key, endpoint = endpoint }, nil
end

function credentials.source(): ("env" | "file")?
	if envKey() ~= nil then
		return "env"
	end
	if fileKey() ~= nil then
		return "file"
	end
	return nil
end

function credentials.looksLikeKey(s: string): boolean
	local key = trim(s)
	if string.find(key, "%s") ~= nil then
		return false
	end
	for _, prefix in KEY_PREFIXES do
		if #key > #prefix and string.sub(key, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local SAVE_TIMEOUT_MS = 5000

-- Creates the data directory (700) and the key file (600) in one shell so the key is never
-- world-readable, not even briefly: umask 077 applies at creation, and the key travels on stdin,
-- never in argv. $1 is the key file, $2 the data directory.
local POSIX_SAVE_SCRIPT =
	'umask 077 && mkdir -p "$2" && chmod 700 "$2" && cat > "$1.tmp" && mv -f "$1.tmp" "$1" && chmod 600 "$1"'

-- Stores the key in the plugin data directory. `cb(true)` once it is on disk with owner-only
-- permissions; `cb(false, message)` otherwise. The message never contains the key.
function credentials.save(key: string, cb: (ok: boolean, err: string?) -> ())
	local trimmed = trim(key)
	if trimmed == "" then
		cb(false, "Paste a Linear API key first.")
		return
	end
	local path = keyFilePath()
	local dir = tern.plugin.data
	local body = tern.json.encode({ apiKey = trimmed })

	if tern.runtime.os == "windows" then
		local written = pcall(function()
			tern.fs.mkdir(dir)
			tern.fs.write(path, body)
		end)
		if written then
			cb(true, nil)
		else
			cb(false, "Could not save the API key in the plugin data directory.")
		end
		return
	end

	local dirOk = pcall(tern.fs.mkdir, dir)
	if not dirOk then
		cb(false, "Could not create the plugin data directory.")
		return
	end
	local started, startError = pcall(function()
		tern.process.run(
			{ "/bin/sh", "-c", POSIX_SAVE_SCRIPT, "sh", path, dir },
			{ stdin = body, timeout_ms = SAVE_TIMEOUT_MS },
			function(result)
				if result.status == 0 then
					cb(true, nil)
				else
					cb(false, "Could not save the key (exit " .. tostring(result.status) .. ").")
				end
			end
		)
	end)
	if not started then
		-- A spawn failure raises; its message names the command, not the key (the key is only in stdin).
		cb(false, "Could not save the key: " .. tostring(startError))
	end
end

-- Removes the stored key. Returns false and a message when the file is still there afterwards.
function credentials.clear(): (boolean, string?)
	local path = keyFilePath()
	pcall(function()
		if tern.fs.exists(path) then
			tern.fs.remove(path)
		end
	end)
	local existsOk, exists = pcall(tern.fs.exists, path)
	if not existsOk or exists then
		return false, "Could not delete the stored key at " .. path .. "."
	end
	return true, nil
end

return credentials
