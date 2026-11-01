--!strict
-- Notion: reference parsing, the REST calls and the board model. Pure host
-- code with no block state, so host.luau only deals with keys and views.
--
-- API calls (Notion-Version 2026-03-11):
--   GET   /v1/databases/{id}                -> the database's data sources
--   GET   /v1/views?database_id={id}        -> the database's views
--   GET   /v1/views/{id}                    -> a view: group-by, filter, sorts, visible properties
--   POST  /v1/views/{id}/queries            -> the view's own rows, in its order
--   GET   /v1/views/{id}/queries/{query}    -> the next page of those rows
--   GET   /v1/data_sources/{id}             -> the property schema and the column options
--   POST  /v1/data_sources/{id}/query       -> the rows' properties
--   GET   /v1/pages/{id}                    -> a row the query missed, or a parent item's title
--   GET   /v1/pages/{id}/markdown           -> a card's content
--   PATCH /v1/pages/{id}                    -> moves a card (writes its group property)
--   POST  /v1/pages                         -> creates a card
--   GET   /v1/users                         -> people to assign

local M = {}

local NOTION_VERSION = "2026-03-11"
local DEFAULT_BASE = "https://api.notion.com"
local TIMEOUT_MS = 30 * 1000
local PAGE_SIZE = 100
local MAX_PAGES = 5 -- 500 cards
local MAX_VIEW_PROBES = 12
local MAX_PARENTS = 24 -- parent items looked up per read; the rest show no line
local MAX_MISSING = 40 -- rows of the view the data source query did not return
local VIEWS_TTL = 240 -- seconds a database's view list is reused

export type Ref = { database: string, view: string?, group: string? }

-- The kinds of property a board can group by.
local GROUP_KINDS: { [string]: boolean } = {
	status = true,
	select = true,
	multi_select = true,
	people = true,
	relation = true,
	checkbox = true,
}

-- Why a call failed. `kind`: network, auth, forbidden, notfound, rate, nogroup, failed.
export type Problem = { kind: string, text: string, detail: string? }

export type Tag = { text: string, tone: string }
export type Person = { id: string, name: string, avatar: string? }
export type Sprint = { id: string, name: string, state: string?, order: number }
export type Icon = { emoji: string?, url: string? }
export type BoardInfo = { database: string, name: string, project: string?, icon: Icon? }
export type Groupable = { name: string, kind: string }
export type Field = { name: string, text: string, ids: { string }? }
export type ViewInfo = { id: string, name: string }

export type Card = {
	id: string,
	title: string,
	url: string,
	meta: { string },
	tags: { Tag },
	icon: Icon?,
	people: { Person },
	assignees: { Person }, -- the people the view shows on the card
	group_values: { string }, -- its values of the group property (option names, user or page ids)
	fields: { Field },
	parent_id: string?,
	parent: string?,
}

-- `option` is the option name that writes this column's value: a status
-- column made from a status group writes the group's first option.
export type Column = { key: string, name: string, tone: string, cards: { Card }, option: string? }

export type Board = {
	title: string,
	view_id: string?,
	view_name: string?,
	view_url: string?,
	views: { ViewInfo },
	url: string?,
	source: string,
	group: string,
	group_type: string,
	title_prop: string?,
	people_prop: string?,
	parent_prop: string?,
	sprint_prop: string?, -- the relation to the sprints a card belongs to
	sprint_source: string?, -- the data source those sprints live in
	sprints: { Sprint }, -- those sprints: current first, then upcoming, then the rest
	project: string?, -- the top-level page the database sits in
	icon: Icon?, -- the database's icon
	groupable: { Groupable }, -- the properties the board can group by
	columns: { Column },
	people: { Person },
	parents: { Person },
	total: number,
	truncated: boolean,
	-- The view's filter or sort was refused by the query endpoint and the view
	-- query couldn't stand in: every row shows.
	filter_dropped: boolean,
	note: string?,
}

-- Notion option colors to Tern tones.
local TONES: { [string]: string } = {
	default = "muted",
	gray = "muted",
	brown = "neutral",
	orange = "warning",
	yellow = "warning",
	green = "success",
	blue = "info",
	purple = "accent",
	pink = "accent",
	red = "error",
}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function tone_of(color: any): string
	return TONES[tostring(color)] or "neutral"
end

-- A page's or database's icon: an emoji, or a picture to fetch.
local function read_icon(icon: any): Icon?
	if type(icon) ~= "table" then
		return nil
	end
	if icon.type == "emoji" and type(icon.emoji) == "string" then
		return { emoji = icon.emoji }
	end
	-- One of Notion's own icons (the "Icons" tab): an SVG it serves by name and color.
	local builtin: any = icon.icon
	if icon.type == "icon" and type(builtin) == "table" and type(builtin.name) == "string" then
		local at = tern.getenv("NOTION_ICONS_BASE") or "https://www.notion.so/icons"
		local color = if type(builtin.color) == "string" then builtin.color else "gray"
		return { url = at .. "/" .. builtin.name .. "_" .. color .. ".svg" }
	end
	for _, kind in { "external", "file", "custom_emoji" } do
		local inner: any = icon[kind]
		if icon.type == kind and type(inner) == "table" and type(inner.url) == "string" then
			return { url = inner.url }
		end
	end
	return nil
end

local function norm(id: string): string
	return (string.lower((string.gsub(id, "%-", ""))))
end

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- References ---------------------------------------------------------------

function M.is_token(text: string): boolean
	local t = string.gsub(text, "%s+", "")
	return string.match(t, "^ntn_[%w]+$") ~= nil or string.match(t, "^secret_[%w]+$") ~= nil
end

-- The last 32 hex digits of `s` once dashes are gone: a Notion id, bare or
-- in a UUID, or at the end of a page-title slug.
local function trailing_id(s: string): string?
	local bare = string.gsub(s, "%-", "")
	local run = string.match(bare, "(%x+)$")
	if run and #run >= 32 then
		return string.lower(string.sub(run, #run - 31))
	end
	return nil
end

-- The database (and view, when the link has `?v=`) a pasted Notion link or id names.
function M.parse_ref(text: string): Ref?
	local t = string.gsub(text, "%s+", "")
	if t == "" or M.is_token(t) then
		return nil
	end
	local path, query = string.match(t, "^([^?#]*)%??([^#]*)")
	if not path then
		return nil
	end
	path = string.gsub(path, "/+$", "")
	local segment = string.match(path, "([^/]+)$")
	if not segment then
		return nil
	end
	-- A link must point at Notion; a bare id is fine too.
	if string.find(path, "/", 1, true) and not string.find(string.lower(path), "notion", 1, true) then
		return nil
	end
	local database = trailing_id(segment)
	if not database then
		return nil
	end
	local view: string? = nil
	local v = string.match(query or "", "v=([%x%-]+)")
	if v then
		view = trailing_id(v)
	end
	return { database = database, view = view }
end

-- Requests -----------------------------------------------------------------

local function base(): string
	local b = tern.getenv("NOTION_API_BASE")
	if b and b ~= "" then
		return (string.gsub(b, "/+$", ""))
	end
	return DEFAULT_BASE
end

local function first_line(text: string, max: number): string
	local line = string.match(text, "[^\r\n]+") or ""
	if #line > max then
		line = string.sub(line, 1, max) .. "…"
	end
	return line
end

-- What a failed reply means for the person looking at the block.
local function problem_of(status: number, err: string?, data: any): Problem
	if err then
		return { kind = "network", text = "Could not reach Notion.", detail = first_line(err, 200) }
	end
	local message = if type(data) == "table" and type(data.message) == "string" then data.message else nil
	if status == 401 then
		return { kind = "auth", text = "Notion rejected the token.", detail = message }
	elseif status == 403 then
		return {
			kind = "forbidden",
			text = "The integration is not allowed to do that.",
			detail = message or "Check the integration's capabilities in Notion.",
		}
	elseif status == 404 then
		return {
			kind = "notfound",
			text = "Notion could not find that for this integration.",
			detail = message,
		}
	elseif status == 429 then
		return { kind = "rate", text = "Notion is rate limiting requests. Try again in a moment.", detail = message }
	end
	return { kind = "failed", text = "Notion answered " .. status .. ".", detail = message }
end

type Reply = { data: any, problem: Problem? }

local function call(token: string, method: string, path: string, body: any?, cb: (Reply) -> ())
	local headers: { [string]: string } = {
		Authorization = "Bearer " .. token,
		["Notion-Version"] = NOTION_VERSION,
	}
	local opts: FetchOptions = { method = method, headers = headers, timeout_ms = TIMEOUT_MS }
	if body ~= nil then
		headers["Content-Type"] = "application/json"
		opts.body = tern.json.encode(body)
	end
	tern.fetch(base() .. path, opts, function(r: FetchResult, _)
		local ok, data = pcall(tern.json.decode, r.body)
		if not ok then
			data = nil
		end
		if r.error then
			cb({ data = nil, problem = problem_of(0, r.error, nil) })
		elseif r.status >= 300 then
			cb({ data = data, problem = problem_of(r.status, nil, data) })
		elseif type(data) ~= "table" then
			cb({ data = nil, problem = { kind = "failed", text = "Notion sent something other than JSON." } })
		else
			cb({ data = data, problem = nil })
		end
	end)
end

-- Reading Notion's objects ------------------------------------------------------

local function plain(rich: any): string
	local out: { string } = {}
	if type(rich) == "table" then
		for _, part in rich do
			if type(part) == "table" and type(part.plain_text) == "string" then
				table.insert(out, part.plain_text)
			end
		end
	end
	return table.concat(out)
end

local function fmt_date(iso: any): string?
	if type(iso) ~= "string" then
		return nil
	end
	local m, d = string.match(iso, "^%d+-(%d+)-(%d+)")
	local month = if m then tonumber(m) else nil
	if not (month and d and MONTHS[month]) then
		return nil
	end
	return MONTHS[month] .. " " .. (tonumber(d) :: number)
end

local function sorted_names(props: { [string]: any }): { string }
	local names: { string } = {}
	for name in props do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- The relation that makes a card a sub-item of another.
local function is_parent(name: string): boolean
	return name == "Parent item" or name == "Parent task"
end

-- A property value as the detail panel's text, or nil when it is empty.
local function field_text(kind: string, value: any): string?
	local text: string? = nil
	if (kind == "select" or kind == "status") and type(value) == "table" then
		text = value.name
	elseif kind == "multi_select" and type(value) == "table" then
		local names: { string } = {}
		for _, option in value do
			if type(option) == "table" and type(option.name) == "string" then
				table.insert(names, option.name)
			end
		end
		text = table.concat(names, ", ")
	elseif kind == "people" and type(value) == "table" then
		local names: { string } = {}
		for _, person in value do
			if type(person) == "table" and type(person.name) == "string" then
				table.insert(names, person.name)
			end
		end
		text = table.concat(names, ", ")
	elseif kind == "date" and type(value) == "table" then
		local from = fmt_date(value.start)
		local to = fmt_date(value["end"])
		if from then
			text = if to and to ~= from then from .. " → " .. to else from
		end
	elseif kind == "number" and type(value) == "number" then
		text = tostring(value)
	elseif kind == "checkbox" then
		text = if value == true then "Yes" else "No"
	elseif (kind == "url" or kind == "email" or kind == "phone_number") and type(value) == "string" then
		text = value
	elseif kind == "rich_text" then
		text = plain(value)
	elseif kind == "relation" and type(value) == "table" and #value > 0 then
		text = #value .. " linked"
	elseif kind == "created_time" or kind == "last_edited_time" then
		text = if type(value) == "string" then string.sub(value, 1, 10) else nil
	elseif kind == "unique_id" and type(value) == "table" and value.number then
		text = (if type(value.prefix) == "string" then value.prefix .. "-" else "") .. tostring(value.number)
	elseif kind == "formula" and type(value) == "table" then
		local inner = value[tostring(value.type)]
		if type(inner) == "string" or type(inner) == "number" then
			text = tostring(inner)
		elseif type(inner) == "boolean" then
			text = if inner then "Yes" else "No"
		end
	end
	if text == "" then
		return nil
	end
	return text
end

-- The card property names the board view shows, in the view's order, or nil
-- when the view lists none (then every property shows, alphabetically).
local function visible_props(schema: { [string]: any }, view: any, group_name: string): { string }?
	local config: any = if type(view) == "table" then view.configuration else nil
	local entries: any = if type(config) == "table" then config.properties else nil
	if type(entries) ~= "table" or #entries == 0 then
		return nil
	end
	local names: { string } = {}
	for _, entry in entries do
		if type(entry) == "table" and type(entry.property_id) == "string" and entry.visible ~= false then
			for name, prop in schema do
				if type(prop) == "table" and (prop.id == entry.property_id or name == entry.property_id) then
					if prop.type ~= "title" and name ~= group_name then
						table.insert(names, name)
					end
					break
				end
			end
		end
	end
	return names
end

-- One page as a card: its title, the shown properties as muted meta text or
-- tags, and every property as a field for the detail panel.
local function read_card(page: any, group: string, shown: { string }?): Card?
	if type(page) ~= "table" or page.object ~= "page" or type(page.id) ~= "string" then
		return nil
	end
	local props: { [string]: any } = if type(page.properties) == "table" then page.properties else {}
	local card: Card = {
		id = page.id,
		title = "",
		url = if type(page.url) == "string" then page.url else "https://www.notion.so/" .. string.gsub(page.id, "%-", ""),
		meta = {},
		tags = {},
		icon = read_icon(page.icon),
		people = {},
		assignees = {},
		fields = {},
		parent_id = nil,
		parent = nil,
		group_values = {},
	}
	-- Fields: the shown properties first, in the view's order, then the rest.
	local order: { string } = {}
	local placed: { [string]: boolean } = {}
	local listed: { string } = shown or {}
	for _, name in listed do
		placed[name] = true
		table.insert(order, name)
	end
	for _, name in sorted_names(props) do
		if not placed[name] then
			table.insert(order, name)
		end
	end
	for _, name in order do
		local prop = props[name]
		local kind = if type(prop) == "table" then prop.type else nil
		if kind == "title" then
			card.title = plain(prop.title)
		elseif type(kind) == "string" then
			local value = prop[kind]
			if kind == "people" and type(value) == "table" then
				for _, person in value do
					if type(person) == "table" and type(person.id) == "string" and type(person.name) == "string" then
						table.insert(card.people, {
							id = person.id,
							name = person.name,
							avatar = if type(person.avatar_url) == "string" then person.avatar_url else nil,
						})
					end
				end
			end
			local text = field_text(kind, value)
			if text and name ~= group then
				local ids: { string }? = nil
				if kind == "relation" and type(value) == "table" then
					ids = {}
					for _, related in value do
						if type(related) == "table" and type(related.id) == "string" then
							table.insert(ids :: { string }, related.id)
						end
					end
				end
				table.insert(card.fields, { name = name, text = text, ids = ids })
			end
		end
	end
	-- Sub-items: Notion shows a card's parent whether or not the view lists the
	-- relation. Its title is read in `resolve_parents`.
	for _, name in sorted_names(props) do
		local prop = props[name]
		if type(prop) == "table" and prop.type == "relation" and is_parent(name) then
			local related: any = prop.relation
			if type(related) == "table" and type(related[1]) == "table" and type(related[1].id) == "string" then
				card.parent_id = related[1].id
			end
		end
	end
	local meta_names: { string } = shown or sorted_names(props)
	for _, name in meta_names do
		local prop = props[name]
		local kind = if type(prop) == "table" then prop.type else nil
		if name ~= group and kind ~= "relation" and kind ~= "title" and type(kind) == "string" then
			local value = prop[kind]
			if kind == "people" and type(value) == "table" then
				for _, person in value do
					if type(person) == "table" and type(person.name) == "string" and type(person.id) == "string" then
						table.insert(card.assignees, {
							id = person.id,
							name = person.name,
							avatar = if type(person.avatar_url) == "string" then person.avatar_url else nil,
						})
					end
				end
			elseif kind == "date" and type(value) == "table" then
				local from = fmt_date(value.start)
				local to = fmt_date(value["end"])
				if from then
					table.insert(card.meta, if to and to ~= from then from .. " → " .. to else from)
				end
			elseif (kind == "select" or kind == "status") and type(value) == "table" and type(value.name) == "string" then
				table.insert(card.tags, { text = value.name, tone = tone_of(value.color) })
			elseif kind == "multi_select" and type(value) == "table" then
				for _, option in value do
					if type(option) == "table" and type(option.name) == "string" then
						table.insert(card.tags, { text = option.name, tone = tone_of(option.color) })
					end
				end
			end
		end
	end
	return card
end

local function find_group(schema: { [string]: any }, view: any, override: string?): (any?, string?)
	local names = sorted_names(schema)
	if override then
		local chosen = schema[override]
		if type(chosen) == "table" and GROUP_KINDS[tostring(chosen.type)] then
			return chosen, nil
		end
	end
	local wanted = nil
	if type(view) == "table" and type(view.configuration) == "table" and type(view.configuration.group_by) == "table" then
		wanted = view.configuration.group_by.property_id
	end
	local note: string? = nil
	if type(wanted) == "string" then
		for _, name in names do
			local prop = schema[name]
			if type(prop) == "table" and prop.id == wanted then
				if GROUP_KINDS[tostring(prop.type)] then
					return prop, nil
				end
				note = "The view groups by “" .. name .. "” (" .. tostring(prop.type) .. "), which this block can't show; "
				break
			end
		end
	end
	-- No usable view: the first status property, then select, then the others.
	for _, kind in { "status", "select", "multi_select", "people", "checkbox", "relation" } do
		for _, name in names do
			local prop = schema[name]
			if type(prop) == "table" and prop.type == kind then
				return prop, if note then note .. "grouping by “" .. name .. "” instead." else nil
			end
		end
	end
	return nil, note
end


local function build_board(
	db: any,
	view: any,
	views: { ViewInfo },
	source_id: string,
	schema: { [string]: any },
	pages: { any },
	truncated: boolean,
	override: string?
): (Board?, Problem?)
	local group, note = find_group(schema, view, override)
	if not group then
		return nil,
			{
				kind = "nogroup",
				text = "This database has no Status or Select property to make columns from.",
				detail = note,
			}
	end
	local group_name = tostring(group.name)
	local kind = tostring(group.type)
	local config: any = if type(view) == "table" and type(view.configuration) == "table" then view.configuration.group_by else nil
	if type(config) ~= "table" or config.property_id ~= group.id then
		config = {}
	end
	-- A status board can group by Notion's status groups (To-do, In progress,
	-- Complete) instead of by each option.
	local by_group = group.type == "status" and config.group_by == "group"
	local inner: any = group[group.type]
	local source: any = nil
	local option_names: { [string]: string } = {}
	if type(inner) == "table" then
		-- The options as Notion lists them: that is the order of a board's
		-- columns (a status group's own option order is not).
		source = if by_group then inner.groups else inner.options
		for _, option in inner.options or {} do
			if type(option) == "table" and type(option.id) == "string" and type(option.name) == "string" then
				option_names[option.id] = option.name
			end
		end
	end
	local columns: { Column } = {}
	local by_key: { [string]: Column } = {}
	local none: Column = { key = "none", name = "No " .. string.lower(group_name), tone = "muted", cards = {}, option = nil }
	local function add_column(key: string, name: string, tone: string, option: string?): Column
		local column: Column = { key = key, name = name, tone = tone, cards = {}, option = option }
		table.insert(columns, column)
		by_key[key] = column
		return column
	end
	if kind == "checkbox" then
		add_column("false", "Unchecked", "muted", "false")
		add_column("true", "Checked", "success", "true")
	end
	if type(source) == "table" then
		for _, entry in source do
			if type(entry) == "table" and type(entry.id) == "string" and type(entry.name) == "string" then
				local first = if by_group and type(entry.option_ids) == "table" then option_names[tostring(entry.option_ids[1])] else nil
				local column: Column = {
					key = entry.id,
					name = entry.name,
					tone = tone_of(entry.color),
					cards = {},
					option = if by_group then first else entry.name,
				}
				table.insert(columns, column)
				by_key[entry.id] = column
				if by_group then
					for _, option_id in entry.option_ids or {} do
						by_key[tostring(option_id)] = column
					end
				else
					by_key[entry.name] = column
				end
			end
		end
	end
	local shown = visible_props(schema, view, group_name)
	local total = 0
	local people: { Person } = {}
	local seen_people: { [string]: boolean } = {}
	for _, page in pages do
		local card = read_card(page, group_name, shown)
		if card then
			total += 1
			for _, person in card.people do
				if not seen_people[person.id] then
					seen_people[person.id] = true
					table.insert(people, person)
				end
			end
			local value: any = nil
			if type(page.properties) == "table" and type(page.properties[group_name]) == "table" then
				value = page.properties[group_name][group.type]
			end
			local column = none
			if kind == "status" or kind == "select" then
				if type(value) == "table" then
					local known: Column? = by_key[tostring(value.id)]
					if not known and not by_group then
						known = by_key[tostring(value.name)]
					end
					if known then
						column = known
					elseif type(value.name) == "string" and not by_group then
						-- An option the schema read didn't list (it changed in between).
						local added: Column = {
							key = tostring(value.id or value.name),
							name = value.name,
							tone = tone_of(value.color),
							cards = {},
							option = value.name,
						}
						table.insert(columns, added)
						by_key[value.name] = added
						column = added
					end
				end
			elseif kind == "checkbox" then
				column = by_key[tostring(value == true)] or none
			elseif type(value) == "table" then
				-- Several values (multi-select, people, relation): the card sits
				-- under the first, and keeps all of them for a move.
				local first: string? = nil
				local first_name: string? = nil
				local first_tone = "muted"
				for _, item in value do
					if type(item) == "table" then
						local id: any = if kind == "multi_select" then item.name else item.id
						if type(id) == "string" then
							table.insert(card.group_values, id)
							if not first then
								first = id
								first_name = if type(item.name) == "string" then item.name else nil
								first_tone = if kind == "multi_select" then tone_of(item.color) else "muted"
							end
						end
					end
				end
				if first then
					column = by_key[first] or add_column(first, first_name or "…", first_tone, first)
				end
			end
			table.insert(column.cards, card)
		end
	end
	-- Column order as the view sets it. A status board orders by the status
	-- options themselves (TODO, IN PROGRESS, … as Notion lists them): ascending
	-- keeps that order and descending reverses it. A select board's
	-- ascending and descending sort by name; manual keeps the schema's order.
	local order: any = if type(config.sort) == "table" then config.sort.type else nil
	if group.type == "status" then
		if order == "descending" then
			local reversed: { Column } = {}
			for i = #columns, 1, -1 do
				table.insert(reversed, columns[i])
			end
			columns = reversed
		end
	elseif order == "ascending" or order == "descending" then
		table.sort(columns, function(a, b)
			if order == "ascending" then
				return string.lower(a.name) < string.lower(b.name)
			end
			return string.lower(a.name) > string.lower(b.name)
		end)
	end
	if kind == "people" then
		table.sort(columns, function(a, b)
			return string.lower(a.name) < string.lower(b.name)
		end)
	end
	if #none.cards > 0 then
		table.insert(columns, 1, none)
	end
	-- The properties writes go to.
	local title_prop: string? = nil
	local people_prop: string? = nil
	local parent_prop: string? = nil
	local sprint_prop: string? = nil
	local sprint_source: string? = nil
	for _, name in sorted_names(schema) do
		local prop = schema[name]
		if type(prop) == "table" then
			if prop.type == "title" then
				title_prop = name
			elseif prop.type == "people" and (people_prop == nil or string.find(string.lower(name), "assign", 1, true)) then
				people_prop = name
			elseif prop.type == "relation" and is_parent(name) then
				parent_prop = name
			elseif
				prop.type == "relation"
				and string.find(string.lower(name), "sprint", 1, true)
				and type(prop.relation) == "table"
				and type(prop.relation.data_source_id) == "string"
			then
				sprint_prop = name
				sprint_source = prop.relation.data_source_id
			end
		end
	end
	local groupable: { Groupable } = {}
	for _, name in sorted_names(schema) do
		local prop = schema[name]
		if type(prop) == "table" and GROUP_KINDS[tostring(prop.type)] then
			table.insert(groupable, { name = name, kind = tostring(prop.type) })
		end
	end
	local board: Board = {
		title = plain(db.title),
		view_id = if type(view) == "table" and type(view.id) == "string" then view.id else nil,
		view_name = if type(view) == "table" and type(view.name) == "string" and view.name ~= "" then view.name else nil,
		view_url = if type(view) == "table" and type(view.url) == "string" then view.url else nil,
		views = views,
		url = if type(db.url) == "string" then db.url else nil,
		source = source_id,
		group = group_name,
		group_type = tostring(group.type),
		title_prop = title_prop,
		people_prop = people_prop,
		parent_prop = parent_prop,
		sprint_prop = sprint_prop,
		sprint_source = sprint_source,
		columns = columns,
		people = people,
		parents = {},
		sprints = {},
		groupable = groupable,
		total = total,
		truncated = truncated,
		filter_dropped = false,
		note = note,
	}
	if board.title == "" then
		board.title = "Untitled"
	end
	return board, nil
end

-- Loading ------------------------------------------------------------------

local views_cache: { [string]: { at: number, list: { any } } } = {}

-- The database's views that group rows (boards, grouped tables), fetched whole.
local function list_views(token: string, database: string, cb: ({ any }) -> ())
	local cached = views_cache[database]
	if cached and os.time() - cached.at < VIEWS_TTL then
		return cb(cached.list)
	end
	call(token, "GET", "/v1/views?database_id=" .. database, nil, function(r)
		local refs: any = if r.data then r.data.results else nil
		if r.problem or type(refs) ~= "table" then
			return cb({})
		end
		local found: { any } = {}
		local function probe(i: number)
			local item = refs[i]
			if i > MAX_VIEW_PROBES or type(item) ~= "table" or type(item.id) ~= "string" then
				views_cache[database] = { at = os.time(), list = found }
				return cb(found)
			end
			call(token, "GET", "/v1/views/" .. item.id, nil, function(v)
				local config: any = if v.data then v.data.configuration else nil
				local group: any = if type(config) == "table" then config.group_by else nil
				if type(group) == "table" and (group.type == "status" or group.type == "select") then
					table.insert(found, v.data)
				end
				probe(i + 1)
			end)
		end
		probe(1)
	end)
end

-- The view to show and the views to switch between. The linked view wins;
-- else a board view named "current…" (a sprint board), else the first board
-- view; `nil` when there is none, and the board groups by its first status or
-- select property, unfiltered.
local function pick_view(token: string, ref: Ref, cb: (any?, { ViewInfo }) -> ())
	list_views(token, ref.database, function(list)
		local function choose(linked: any?)
			local all: { any } = {}
			if linked then
				table.insert(all, linked)
			end
			for _, v in list do
				if not (linked and norm(tostring(v.id)) == norm(tostring(linked.id))) then
					table.insert(all, v)
				end
			end
			local infos: { ViewInfo } = {}
			for _, v in all do
				if type(v.id) == "string" then
					table.insert(infos, { id = v.id, name = if type(v.name) == "string" and v.name ~= "" then v.name else "Untitled view" })
				end
			end
			if linked then
				return cb(linked, infos)
			end
			local first_board: any = nil
			for _, v in all do
				if v.type == "board" then
					first_board = first_board or v
					if string.find(string.lower(tostring(v.name)), "current", 1, true) then
						return cb(v, infos)
					end
				end
			end
			cb(first_board or all[1], infos)
		end
		if ref.view then
			call(token, "GET", "/v1/views/" .. ref.view, nil, function(r)
				choose(if r.problem then nil else r.data)
			end)
		else
			choose(nil)
		end
	end)
end

-- The ids of the view's own rows in its own order, or nil when the view
-- can't be queried: that is how a "current sprint" filter, which the data
-- source query may refuse, still applies.
local function view_order(token: string, view: any, cb: ({ string }?) -> ())
	if type(view) ~= "table" or type(view.id) ~= "string" then
		return cb(nil)
	end
	local ids: { string } = {}
	local view_id: string = view.id
	local function take(data: any)
		for _, item in data.results or {} do
			if type(item) == "table" and type(item.id) == "string" then
				table.insert(ids, norm(item.id))
			end
		end
	end
	call(token, "POST", "/v1/views/" .. view_id .. "/queries", { page_size = PAGE_SIZE }, function(first)
		if first.problem or not first.data then
			return cb(nil)
		end
		local query_id: any = first.data.id
		take(first.data)
		local function more(data: any, n: number)
			if data.has_more == true and type(data.next_cursor) == "string" and type(query_id) == "string" and n < MAX_PAGES then
				local path = "/v1/views/" .. view_id .. "/queries/" .. query_id .. "?page_size=" .. PAGE_SIZE .. "&start_cursor=" .. encode(data.next_cursor)
				call(token, "GET", path, nil, function(r)
					if r.problem or not r.data then
						return cb(ids)
					end
					take(r.data)
					more(r.data, n + 1)
				end)
			else
				cb(ids)
			end
		end
		more(first.data, 1)
	end)
end

-- Every page of the view's rows, up to MAX_PAGES requests. A view filter or
-- sort Notion refuses on this endpoint falls back to an unfiltered read, and
-- the last argument of `cb` says so.
local function query_all(token: string, source: string, view: any, cb: ({ any }?, Problem?, boolean, boolean) -> ())
	local pages: { any } = {}
	local dropped = false
	local function step(cursor: string?, n: number, use_view: boolean)
		local body: { [string]: any } = { page_size = PAGE_SIZE }
		if use_view then
			body.filter = view.filter
			body.sorts = view.sorts
		end
		body.start_cursor = cursor
		call(token, "POST", "/v1/data_sources/" .. source .. "/query", body, function(r)
			if r.problem then
				if use_view and n == 1 and r.problem.kind == "failed" then
					dropped = true
					return step(nil, 1, false)
				end
				return cb(nil, r.problem, false, false)
			end
			for _, page in r.data.results or {} do
				table.insert(pages, page)
			end
			local more = r.data.has_more == true and type(r.data.next_cursor) == "string"
			if more and n < MAX_PAGES then
				step(r.data.next_cursor, n + 1, use_view)
			else
				cb(pages, nil, more, dropped)
			end
		end)
	end
	local filtered = type(view) == "table" and (view.filter ~= nil or view.sorts ~= nil)
	step(nil, 1, filtered)
end

-- The pages the view holds, in its order: `ids` picks and orders them; rows
-- the data source query didn't return are read one by one.
local function arrange(token: string, pages: { any }, ids: { string }, cb: ({ any }) -> ())
	local by_id: { [string]: any } = {}
	for _, page in pages do
		if type(page) == "table" and type(page.id) == "string" then
			by_id[norm(page.id)] = page
		end
	end
	local missing: { string } = {}
	for _, id in ids do
		if not by_id[id] and #missing < MAX_MISSING then
			table.insert(missing, id)
		end
	end
	local function finish()
		local out: { any } = {}
		for _, id in ids do
			if by_id[id] then
				table.insert(out, by_id[id])
			end
		end
		cb(out)
	end
	local function fetch(i: number)
		local id = missing[i]
		if not id then
			return finish()
		end
		call(token, "GET", "/v1/pages/" .. id, nil, function(r)
			if r.data and r.data.object == "page" then
				by_id[id] = r.data
			end
			fetch(i + 1)
		end)
	end
	fetch(1)
end

-- Parent page titles by page id, kept across refreshes: a parent rarely changes.
local parent_titles: { [string]: string } = {}

-- Looks up the titles of the cards' parent items, one request at a time to
-- stay under Notion's rate limit; a parent that can't be read just shows no line.
local function resolve_parents(token: string, board: Board, done: () -> ())
	local wanted: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, column in board.columns do
		for _, card in column.cards do
			local id = card.parent_id
			if id and not parent_titles[id] and not seen[id] and #wanted < MAX_PARENTS then
				seen[id] = true
				table.insert(wanted, id)
			end
		end
	end
	local function finish()
		local listed: { [string]: boolean } = {}
		for _, column in board.columns do
			for _, card in column.cards do
				local id = card.parent_id
				if id then
					card.parent = parent_titles[id]
					if card.parent and not listed[id] then
						listed[id] = true
						table.insert(board.parents, { id = id, name = card.parent })
					end
				end
			end
		end
		table.sort(board.parents, function(a, b)
			return string.lower(a.name) < string.lower(b.name)
		end)
		done()
	end
	local function fetch(i: number)
		local id = wanted[i]
		if not id then
			return finish()
		end
		call(token, "GET", "/v1/pages/" .. id, nil, function(r)
			local props: any = if r.data then r.data.properties else nil
			if type(props) == "table" then
				for _, prop in props do
					if type(prop) == "table" and prop.type == "title" then
						parent_titles[id] = plain(prop.title)
					end
				end
			end
			fetch(i + 1)
		end)
	end
	fetch(1)
end

-- The titles of the pages a field points at, read once and kept; `done` runs
-- when they are known (or could not be read).
function M.titles(token: string, ids: { string }, done: () -> ()): nil
	local wanted: { string } = {}
	for _, id in ids do
		if not parent_titles[id] and #wanted < MAX_PARENTS then
			table.insert(wanted, id)
		end
	end
	local function fetch(i: number)
		local id = wanted[i]
		if not id then
			return done()
		end
		call(token, "GET", "/v1/pages/" .. id, nil, function(r)
			local props: any = if r.data then r.data.properties else nil
			if type(props) == "table" then
				for _, prop in props do
					if type(prop) == "table" and prop.type == "title" then
						parent_titles[id] = plain(prop.title)
					end
				end
			end
			fetch(i + 1)
		end)
	end
	fetch(1)
	return nil
end

-- A field as text: related pages by title once `M.titles` has read them.
function M.field_text(field: Field): string
	local ids = field.ids
	if not ids then
		return field.text
	end
	local names: { string } = {}
	for _, id in ids do
		local title = parent_titles[id]
		if title and title ~= "" then
			table.insert(names, title)
		end
	end
	if #names == 0 then
		return field.text
	end
	if #names < #ids then
		table.insert(names, "+" .. (#ids - #names) .. " more")
	end
	return table.concat(names, ", ")
end

-- Pages seen on the way up from a database: their title and their parent page.
local page_nodes: { [string]: { title: string, parent: string? } } = {}

-- The project a page belongs to: the title of the top-level page above it
-- (or itself). `budget` caps the requests one list may make; nil when the
-- chain can't be read.
local function project_of(token: string, page_id: string, depth: number, budget: { number }, cb: (string?) -> ())
	local function step(node: { title: string, parent: string? })
		if node.parent and depth < 8 then
			return project_of(token, node.parent, depth + 1, budget, cb)
		end
		cb(if node.title ~= "" then node.title else nil)
	end
	local known = page_nodes[page_id]
	if known then
		return step(known)
	end
	if budget[1] <= 0 then
		return cb(nil)
	end
	budget[1] -= 1
	call(token, "GET", "/v1/pages/" .. page_id, nil, function(r)
		if r.problem or not r.data then
			return cb(nil)
		end
		local title = ""
		local props: any = r.data.properties
		if type(props) == "table" then
			for _, prop in props do
				if type(prop) == "table" and prop.type == "title" then
					title = plain(prop.title)
				end
			end
		end
		local above: any = r.data.parent
		local node = { title = title, parent = if type(above) == "table" and type(above.page_id) == "string" then above.page_id else nil }
		page_nodes[page_id] = node
		step(node)
	end)
end

local function project_of_parent(token: string, parent: any, cb: (string?) -> ())
	if type(parent) == "table" and type(parent.page_id) == "string" then
		project_of(token, parent.page_id, 1, { 8 }, cb)
	else
		cb(nil)
	end
end

local sprints_cache: { [string]: { at: number, list: { Sprint } } } = {}

-- The sprints a data source holds, in Notion's order (newest first, as it lists
-- them); `order` is the place in that list. Empty when it can't be read. Kept
-- a few minutes.
local function load_sprints(token: string, source: string, cb: ({ Sprint }) -> ())
	local cached = sprints_cache[source]
	if cached and os.time() - cached.at < VIEWS_TTL then
		return cb(cached.list)
	end
	call(token, "POST", "/v1/data_sources/" .. source .. "/query", { page_size = 50 }, function(r)
		local out: { Sprint } = {}
		local results: any = if r.data then r.data.results else nil
		if type(results) == "table" then
			for at, page in results do
				if type(page) == "table" and type(page.id) == "string" and type(page.properties) == "table" then
					local name = ""
					local state: string? = nil
					for _, prop_name in sorted_names(page.properties) do
						local prop = page.properties[prop_name]
						if type(prop) == "table" then
							if prop.type == "title" then
								name = plain(prop.title)
							elseif (prop.type == "status" or prop.type == "select") and state == nil then
								local value: any = prop[prop.type]
								if type(value) == "table" and type(value.name) == "string" then
									state = value.name
								end
							end
						end
					end
					table.insert(out, { id = page.id, name = if name ~= "" then name else "Untitled", state = state, order = at })
				end
			end
		end
		if not r.problem then
			sprints_cache[source] = { at = os.time(), list = out }
		end
		cb(out)
	end)
end

local function sprint_rank(sprint: Sprint): number
	local lowered = string.lower(sprint.state or "")
	return if lowered == "current" then 1 elseif lowered == "next" or lowered == "future" then 2 else 3
end

-- Reads what a board needs besides its cards: the sprints (a board without
-- any, or whose sprints can't be read, has no sprint choices or sprint column)
-- and the titles of the pages a relation column stands for. `board.sprints`
-- lists the current sprint first, then the upcoming, then the rest.
local function settle(token: string, board: Board, cb: () -> ())
	local function columns_done()
		if board.group_type ~= "relation" then
			return cb()
		end
		local by_sprint: { [string]: Sprint } = {}
		if board.group == board.sprint_prop then
			for _, sprint in board.sprints do
				by_sprint[sprint.id] = sprint
			end
		end
		local none: Column? = nil
		local others: { Column } = {}
		local unknown: { string } = {}
		for _, column in board.columns do
			if column.key == "none" then
				none = column
			else
				table.insert(others, column)
				if not by_sprint[column.key] then
					table.insert(unknown, column.key)
				end
			end
		end
		M.titles(token, unknown, function()
			local named: { { column: Column, rank: number } } = {}
			local have: { [string]: boolean } = {}
			for _, column in others do
				local sprint = by_sprint[column.key]
				if sprint then
					column.name = sprint.name
					column.tone = if sprint_rank(sprint) == 1 then "accent" else "muted"
					have[column.key] = true
					table.insert(named, { column = column, rank = sprint.order })
				else
					column.name = parent_titles[column.key] or "Untitled"
					table.insert(named, { column = column, rank = math.huge })
				end
			end
			if board.group == board.sprint_prop then
				-- Sprints with cards, and the current and upcoming ones even when empty:
				-- oldest on the left.
				for _, sprint in board.sprints do
					if not have[sprint.id] and sprint_rank(sprint) <= 2 then
						local empty: Column = {
							key = sprint.id,
							name = sprint.name,
							tone = if sprint_rank(sprint) == 1 then "accent" else "muted",
							cards = {},
							option = sprint.id,
						}
						table.insert(named, { column = empty, rank = sprint.order })
					end
				end
				table.sort(named, function(a, b)
					if a.rank ~= b.rank then
						return a.rank > b.rank
					end
					return string.lower(a.column.name) < string.lower(b.column.name)
				end)
			else
				table.sort(named, function(a, b)
					return string.lower(a.column.name) < string.lower(b.column.name)
				end)
			end
			local out: { Column } = {}
			if none then
				table.insert(out, none)
			end
			for _, item in named do
				table.insert(out, item.column)
			end
			board.columns = out
			cb()
		end)
	end
	local source = board.sprint_source
	if not source then
		return columns_done()
	end
	load_sprints(token, source, function(list)
		if #list == 0 then
			-- No sprints to choose from: the board doesn't use them.
			local gone = board.sprint_prop
			local kept: { Groupable } = {}
			for _, item in board.groupable do
				if item.name ~= gone then
					table.insert(kept, item)
				end
			end
			board.groupable = kept
			board.sprint_prop = nil
			board.sprint_source = nil
		else
			table.sort(list, function(a, b)
				local ra, rb = sprint_rank(a), sprint_rank(b)
				if ra ~= rb then
					return ra < rb
				end
				return a.order < b.order
			end)
			board.sprints = list
		end
		columns_done()
	end)
end

-- Reads the board `ref` names. Calls `done` once, later, with the board or
-- the problem.
function M.load(token: string, ref: Ref, done: (Board?, Problem?) -> ()): nil
	call(token, "GET", "/v1/databases/" .. ref.database, nil, function(db)
		if db.problem then
			return done(nil, db.problem)
		end
		local sources: any = db.data.data_sources
		if type(sources) ~= "table" or type(sources[1]) ~= "table" then
			return done(nil, { kind = "failed", text = "Notion returned a database with no data source." })
		end
		pick_view(token, ref, function(view, infos)
			local source = if type(view) == "table" and type(view.data_source_id) == "string"
				then view.data_source_id
				else tostring(sources[1].id)
			call(token, "GET", "/v1/data_sources/" .. source, nil, function(ds)
				if ds.problem then
					return done(nil, ds.problem)
				end
				local schema: any = ds.data.properties
				if type(schema) ~= "table" then
					return done(nil, { kind = "failed", text = "Notion returned a data source with no properties." })
				end
				view_order(token, view, function(ids)
					query_all(token, source, view, function(pages, problem, truncated, dropped)
						if problem or not pages then
							return done(nil, problem)
						end
						local function build(arranged: { any })
							local board, build_problem = build_board(db.data, view, infos, source, schema, arranged, truncated, ref.group)
							if not board then
								return done(nil, build_problem)
							end
							board.filter_dropped = dropped and ids == nil
							settle(token, board, function()
								project_of_parent(token, db.data.parent, function(name)
									board.project = name
									board.icon = read_icon(db.data.icon)
									resolve_parents(token, board, function()
										done(board, nil)
									end)
								end)
							end)
						end
						if ids then
							arrange(token, pages, ids, build)
						else
							build(pages)
						end
					end)
				end)
			end)
		end)
	end)
	return nil
end

-- Writes ---------------------------------------------------------------------

-- The values a multi-valued property holds after a move: the new one first,
-- the others kept, the one the card leaves dropped.
local function next_values(current: { string }, option: string, from: string?): { string }
	local out: { string } = { option }
	for _, value in current do
		if value ~= option and value ~= from then
			table.insert(out, value)
		end
	end
	return out
end

-- The property value that puts a card in the column `option`: a status, select
-- or checkbox is set outright; the properties that hold several values
-- (multi-select, people, relation) get `next_values`.
local function group_value(board: Board, option: string, current: { string }, from: string?): any
	local kind = board.group_type
	if kind == "status" or kind == "select" then
		local value: { [string]: any } = {}
		value[kind] = { name = option }
		return value
	elseif kind == "checkbox" then
		return { checkbox = option == "true" }
	end
	local items: { any } = {}
	for _, value in next_values(current, option, from) do
		table.insert(items, if kind == "multi_select" then { name = value } else { id = value })
	end
	local out: { [string]: any } = {}
	out[kind] = items
	return out
end

-- Moves a card from the column `from` to the column `option`: writes the group
-- property. A card that holds several values keeps what was sent, so a second
-- move before the next read starts from the right list.
function M.move(token: string, board: Board, card: Card, from: string?, option: string, cb: (Problem?) -> ()): nil
	local properties: { [string]: any } = {}
	properties[board.group] = group_value(board, option, card.group_values, from)
	local kind = board.group_type
	if kind == "multi_select" or kind == "people" or kind == "relation" then
		card.group_values = next_values(card.group_values, option, from)
	end
	call(token, "PATCH", "/v1/pages/" .. card.id, { properties = properties }, function(r)
		cb(r.problem)
	end)
	return nil
end

export type NewCard = { title: string, option: string?, parent_id: string?, person_id: string?, sprint_id: string? }

-- Creates a card in the board's data source.
function M.create(token: string, board: Board, spec: NewCard, cb: (Problem?) -> ()): nil
	local properties: { [string]: any } = {}
	if not board.title_prop then
		cb({ kind = "failed", text = "This data source has no title property." })
		return nil
	end
	properties[board.title_prop] = { title = { { text = { content = spec.title } } } }
	if spec.option then
		properties[board.group] = group_value(board, spec.option, {}, nil)
	end
	if spec.parent_id and board.parent_prop then
		properties[board.parent_prop] = { relation = { { id = spec.parent_id } } }
	end
	if spec.sprint_id and board.sprint_prop and board.sprint_prop ~= board.group then
		properties[board.sprint_prop] = { relation = { { id = spec.sprint_id } } }
	end
	if spec.person_id and board.people_prop and board.people_prop ~= board.group then
		properties[board.people_prop] = { people = { { id = spec.person_id } } }
	end
	local body = { parent = { type = "data_source_id", data_source_id = board.source }, properties = properties }
	call(token, "POST", "/v1/pages", body, function(r)
		cb(r.problem)
	end)
	return nil
end

-- A card's content as markdown.
function M.detail(token: string, card_id: string, cb: (string?, Problem?) -> ()): nil
	call(token, "GET", "/v1/pages/" .. card_id .. "/markdown?markdown_version=v2", nil, function(r)
		if r.problem then
			cb(nil, r.problem)
		else
			cb(if type(r.data.markdown) == "string" then r.data.markdown else "", nil)
		end
	end)
	return nil
end

-- The databases this integration can see, grouped by the project (top-level
-- page) they live in: what to offer when a pane has no board yet.
function M.boards(token: string, cb: ({ BoardInfo }, Problem?) -> ()): nil
	local body = { filter = { property = "object", value = "data_source" }, page_size = 100 }
	call(token, "POST", "/v1/search", body, function(r)
		if r.problem or not r.data then
			return cb({}, r.problem)
		end
		local found: { { info: BoardInfo, page: string? } } = {}
		local results: any = r.data.results
		if type(results) == "table" then
			for _, item in results do
				local parent: any = if type(item) == "table" then item.parent else nil
				if type(item) == "table" and item.in_trash ~= true and type(parent) == "table" and type(parent.database_id) == "string" then
					local name = plain(item.title)
					local above: any = item.database_parent
					table.insert(found, {
						info = {
							database = parent.database_id,
							name = if name ~= "" then name else "Untitled",
							icon = read_icon(item.icon),
						},
						page = if type(above) == "table" and type(above.page_id) == "string" then above.page_id else nil,
					})
				end
			end
		end
		local budget = { 40 }
		local function finish()
			local out: { BoardInfo } = {}
			for _, entry in found do
				table.insert(out, entry.info)
			end
			table.sort(out, function(a, b)
				local pa, pb = string.lower(a.project or ""), string.lower(b.project or "")
				if pa ~= pb then
					return pa < pb
				end
				return string.lower(a.name) < string.lower(b.name)
			end)
			cb(out, nil)
		end
		local function nxt(i: number)
			local entry = found[i]
			if not entry then
				return finish()
			end
			local page = entry.page
			if not page then
				return nxt(i + 1)
			end
			project_of(token, page, 1, budget, function(title)
				entry.info.project = title
				nxt(i + 1)
			end)
		end
		nxt(1)
	end)
	return nil
end

local workspace_names: { [string]: string } = {}

-- The name of the workspace the token belongs to, nil when it can't be told.
function M.workspace(token: string, cb: (string?) -> ()): nil
	local known = workspace_names[token]
	if known then
		cb(known)
		return nil
	end
	call(token, "GET", "/v1/users/me", nil, function(r)
		local bot: any = if r.data then r.data.bot else nil
		if type(bot) == "table" and type(bot.workspace_name) == "string" and bot.workspace_name ~= "" then
			workspace_names[token] = bot.workspace_name
		end
		cb(workspace_names[token])
	end)
	return nil
end

-- The workspace's people, for the assignee list; empty when the integration
-- may not read users.
function M.users(token: string, cb: ({ Person }) -> ()): nil
	call(token, "GET", "/v1/users?page_size=100", nil, function(r)
		local out: { Person } = {}
		if r.data then
			for _, user in r.data.results or {} do
				if type(user) == "table" and user.type == "person" and type(user.id) == "string" and type(user.name) == "string" then
					table.insert(out, { id = user.id, name = user.name, avatar = if type(user.avatar_url) == "string" then user.avatar_url else nil })
				end
			end
		end
		cb(out)
	end)
	return nil
end

return M
