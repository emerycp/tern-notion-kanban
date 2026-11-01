--!strict
-- Looks for a newer version of this plugin: once a day it reads the `version`
-- in the published plugin.toml and says when it is ahead of the installed one.
-- `NOTION_NO_UPDATE_CHECK=1` turns the check off; `NOTION_UPDATE_URL` points it
-- at another file (for testing).

local M = {}

local REPO = "emerycp/tern-notion-kanban"
local URL = "https://raw.githubusercontent.com/" .. REPO .. "/main/plugin.toml"
local INTERVAL = 24 * 60 * 60 -- seconds between looks

local function version_of(toml: string): string?
	return string.match(toml, "\nversion%s*=%s*\"([%d%.]+)\"") or string.match(toml, "^version%s*=%s*\"([%d%.]+)\"")
end

-- The version of the installed plugin.
function M.current(): string?
	local ok, text = pcall(tern.fs.read, "plugin.toml", 8192)
	if not ok then
		return nil
	end
	return version_of(text)
end

-- Whether version `a` is later than `b` (dotted numbers).
function M.newer(a: string, b: string): boolean
	local left: { number } = {}
	local right: { number } = {}
	for part in string.gmatch(a, "%d+") do
		table.insert(left, tonumber(part) :: number)
	end
	for part in string.gmatch(b, "%d+") do
		table.insert(right, tonumber(part) :: number)
	end
	for i = 1, math.max(#left, #right) do
		local x, y = left[i] or 0, right[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

-- The command that installs the latest version over the installed copy.
function M.command(): { string }
	return { "tern", "plugin", "install", "github.com/" .. REPO, "--force" }
end

-- Whether the daily look is on: not turned off in the settings or by the
-- environment.
function M.enabled(): boolean
	return tern.getenv("NOTION_NO_UPDATE_CHECK") == nil and tern.kv.get("update_off") ~= true
end

function M.set_enabled(on: boolean)
	tern.kv.set("update_off", if on then nil else true)
end

-- Calls `cb` with the newer version, or nil when there is none, it can't be
-- told, or the check is off. Answers from the last look when it is under a
-- day old; otherwise asks once and remembers what it heard.
function M.check(cb: (string?) -> ())
	if not M.enabled() then
		return cb(nil)
	end
	local installed = M.current()
	if not installed then
		return cb(nil)
	end
	local function answer(latest: string?)
		cb(if latest and M.newer(latest, installed) then latest else nil)
	end
	local seen: any = tern.kv.get("update_check")
	if type(seen) == "table" and type(seen.at) == "number" and os.time() - seen.at < INTERVAL then
		return answer(if type(seen.latest) == "string" then seen.latest else nil)
	end
	local url = tern.getenv("NOTION_UPDATE_URL") or URL
	tern.fetch(url, { timeout_ms = 10000 }, function(r: FetchResult, _)
		local latest: string? = nil
		if not r.error and r.status == 200 then
			latest = version_of("\n" .. r.body)
		end
		-- A failed look is remembered too, so it is not repeated at every start.
		tern.kv.set("update_check", { at = os.time(), latest = latest })
		answer(latest)
	end)
end

return M
