--!strict
-- API key resolution and storage. The host half cannot reach tern.secrets (window-only),
-- so a stored key lives in `<plugin data>/credentials.json`, chmod 600 on POSIX.
-- Nothing here logs, displays or returns the key except resolve().

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

function credentials.endpoint(): string
	return nonEmpty(tern.getenv("LINEAR_API_URL")) or DEFAULT_ENDPOINT
end

function credentials.resolve(): types.Config?
	local key = envKey() or fileKey()
	if key == nil then
		return nil
	end
	return { key = key, endpoint = credentials.endpoint() }
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

local function restrictPermissions(path: string)
	if tern.runtime.os == "windows" or tern.runtime.os == "ios" then
		return
	end
	local started = pcall(function()
		tern.process.run({ "chmod", "600", path }, function(result)
			if result.status ~= 0 then
				tern.log.warn("tern-linear: chmod 600 on the key file failed with status " .. tostring(result.status))
			end
		end)
	end)
	if not started then
		tern.log.warn("tern-linear: could not start chmod 600 on the key file")
	end
end

function credentials.save(key: string): (boolean, string?)
	local trimmed = trim(key)
	if trimmed == "" then
		return false, "Paste a Linear API key first."
	end
	local path = keyFilePath()
	local written = pcall(function()
		tern.fs.mkdir(tern.plugin.data)
		tern.fs.write(path, tern.json.encode({ apiKey = trimmed }))
	end)
	if not written then
		return false, "Could not save the API key in the plugin data directory."
	end
	restrictPermissions(path)
	return true, nil
end

function credentials.clear()
	local path = keyFilePath()
	pcall(function()
		if tern.fs.exists(path) then
			tern.fs.remove(path)
		end
	end)
end

return credentials
