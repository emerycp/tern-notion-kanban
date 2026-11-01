--!strict
-- The `board` block: a Notion kanban board, read through the Notion API and
-- refreshed every five minutes.
--
-- Which board it shows, first match wins:
--   1. the link in the launch arguments ("Open Notion board from link…")
--   2. a link pasted into the block, or a view picked in it (saved with the pane)
--   3. `.tern/notion.json` in the pane's directory or the nearest parent:
--        { "board": "https://www.notion.so/…?v=…" }
--
-- Keys: ←→ (h/l) columns, ↑↓ (j/k) cards, g/G first/last card, Enter opens the
-- card's panel, o opens it in the browser, b opens the board, H/L (or </>)
-- move the card to the previous/next column, n makes a new card, v switches
-- view (a sprint board, all tasks), r refreshes. Pasting a Notion integration
-- token or a database link into the block sets either.

local ui = tern.ui
local notion = require("./lib/notion")
local notion_md = require("./lib/markdown")
local update = require("./lib/update")

type Ref = notion.Ref
type Board = notion.Board
type Card = notion.Card
type Column = notion.Column
type Person = notion.Person
type Sprint = notion.Sprint
type Icon = notion.Icon
type BoardInfo = notion.BoardInfo
type Problem = notion.Problem

local POLL_MS = 60 * 1000
-- Terminal cells one board column wants; rows a screen has besides its
-- columns' cards; cells a card's padding takes off its width; cells one title
-- character takes in the proportional font; rows a card adds to its text lines
-- (padding and gap). All tuned by eye against a rendered board, not measured.
local COLUMN_CELLS = 24
local CHROME_ROWS = 9
local CARD_SIDE_CELLS = 4
local TITLE_CELLS = 0.85
local CARD_CHROME = 1.5
local CARD_BLOCK_GAP = 0.25 -- rows between a card's blocks
local MAX_TAGS = 3
local MAX_AVATARS = 40 -- pictures read per load
local PICKER_SEARCH_FROM = 7 -- a list longer than this gets a search box
local PANEL_SHARE = 0.45 -- of the block's width the detail panel covers

-- Nerd Fonts' Notion glyph (nf-dev-notion), for the pane title: tab titles are
-- text, and a plugin can't give a tab an icon of its own. Fonts without it
-- show a placeholder box.
local NOTION_GLYPH = utf8.char(0xE848)

-- A card's content: markdown once read.
type Detail = { markdown: string?, loading: boolean, problem: string? }

-- The new-card form. `field` is the one Tab is on: "name", "column", "sprint",
-- "parent" or "person". `picks` holds each choice's value ("none" for no choice).
type Form = {
	name: string,
	cursor: number, -- in characters
	field: string,
	picks: { [string]: string },
	touched: { [string]: boolean }, -- choices the person made, so a late default doesn't override them
	picking: string?, -- the field whose list is open
	query: string, -- what was typed to search that list
	at: number, -- the highlighted row of that list
	busy: boolean,
	error: string?,
}

type Choice = { value: string, label: string, detail: string? }

type State = {
	cx: BlockCx,
	ref: Ref?,
	-- Where `ref` came from: "link", "saved", "paste" or "project".
	source: string,
	-- The person picked another view: save it with the pane even for a project board.
	switched: boolean,
	board: Board?,
	loading: boolean,
	generation: number,
	problem: Problem?,
	fetched: number?,
	col: number,
	row: number,
	first: number,
	tops: { [string]: number },
	panel: boolean,
	details: { [string]: Detail },
	form: Form?,
	-- A card picked up to move (its id), and the column number it would drop into.
	lifted: string?,
	target: number,
	users: { Person },
	only: string?, -- a person's id: show only their cards
	pool: { [string]: { Card } }, -- each column's cards before that filter
	learn: boolean, -- the next pick in the people menu is the person using this machine
	again: boolean, -- a refresh was asked for while one ran
	avatars: { [string]: string }, -- picture url -> Tern blob id
	avatars_asked: { [string]: boolean },
	hide_empty: boolean, -- leave out columns with no cards
	all_columns: { Column }, -- every column of the board, shown or not
	boards: { BoardInfo }?, -- databases offered when there is no board
	boards_loading: boolean,
	pick_at: number, -- the highlighted one
	update: string?, -- a newer version of the plugin, when there is one
	updating: boolean,
	installed: string, -- the version running
	workspace: string?, -- the Notion workspace's name
	previous: { ref: Ref, source: string }?, -- the board left to pick another, for Esc
	last_good: { ref: Ref, source: string }?, -- the last board that loaded
	settings: boolean, -- the settings page is open
	timer: TimerHandle?,
}

-- A pane ID survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	state.loading = false
	state.generation += 1
	state.board = nil
end

-- Blocks have no close hook, so a live callback also checks its pane exists.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

-- A picture's address without the query: Notion signs uploaded files' links,
-- and a new signature must not count as a new picture.
local function picture_key(url: string): string
	return string.match(url, "^[^?#]*") or url
end

-- Pictures (people's, databases' logos), read once per picture and handed to
-- Tern as blobs; one that can't be read is left out, and what showed before
-- (the initials, the default icon) stays.
local function fetch_pictures(state: State, urls: { string })
	for _, url in urls do
		local key = picture_key(url)
		if not state.avatars_asked[key] then
			state.avatars_asked[key] = true
			tern.fetch(url, { timeout_ms = 15000 }, function(result)
				if not alive(state) or result.error or result.status ~= 200 or result.body == "" then
					return
				end
				local mime = string.match(result.headers["content-type"] or "", "^%s*([%w%.%+%-/]+)") or "image/png"
				state.avatars[key] = state.cx:blob(result.body, mime)
				state.cx:render()
			end)
		end
	end
end

-- The pictures a board shows: people's, and the icons of its cards. Each
-- distinct one once, up to MAX_AVATARS a load.
local function fetch_avatars(state: State, board: Board)
	local wanted: { string } = {}
	local seen: { [string]: boolean } = {}
	local function want(url: string?)
		if url then
			local key = picture_key(url)
			if not seen[key] and not state.avatars_asked[key] and #wanted < MAX_AVATARS then
				seen[key] = true
				table.insert(wanted, url)
			end
		end
	end
	for _, column in board.columns do
		for _, card in column.cards do
			want(if card.icon then card.icon.url else nil)
			for _, person in card.assignees do
				want(person.avatar)
			end
		end
	end
	fetch_pictures(state, wanted)
end

-- Setup -----------------------------------------------------------------------

-- A token pasted into a block or set by the "Set Notion token…" command wins
-- over the environment: it is the most recent thing the person did.
local function token(): string?
	local stored = tern.kv.get("token")
	if type(stored) == "string" and stored ~= "" then
		return stored
	end
	for _, name in { "NOTION_TOKEN", "NOTION_API_KEY" } do
		local value = tern.getenv(name)
		if value and value ~= "" then
			return value
		end
	end
	return nil
end

-- The board `.tern/notion.json` names, looking in `cwd` and its parents.
-- The nearest file wins, even a broken one: its error comes back as text.
local function project_ref(cwd: string?): (Ref?, string?)
	local dir = cwd
	for _ = 1, 16 do
		if not dir or dir == "" then
			return nil, nil
		end
		local file = dir .. "/.tern/notion.json"
		if tern.fs.exists(file) then
			local ok, data = pcall(function(): any
				return tern.json.decode(tern.fs.read(file, 16 * 1024))
			end)
			if not ok or type(data) ~= "table" or type(data.board) ~= "string" then
				return nil, file .. " needs a \"board\" key holding a Notion link."
			end
			local ref = notion.parse_ref(data.board)
			if not ref then
				return nil, file .. ": \"board\" is not a Notion database link."
			end
			return ref, nil
		end
		local parent = string.match(dir, "^(.*)[/\\][^/\\]+$")
		if not parent or parent == dir then
			return nil, nil
		end
		dir = parent
	end
	return nil, nil
end

-- Text ------------------------------------------------------------------------

local function ends(s: string, suffix: string): boolean
	return #s >= #suffix and string.sub(s, -#suffix) == suffix
end

local function char_count(s: string): number
	return utf8.len(s) or #s
end

-- `s` with `text` inserted after its first `pos` characters.
local function insert_at(s: string, pos: number, text: string): string
	local at = utf8.offset(s, pos + 1) or (#s + 1)
	return string.sub(s, 1, at - 1) .. text .. string.sub(s, at)
end

-- `s` without its character number `pos` + 1.
local function delete_at(s: string, pos: number): string
	local from = utf8.offset(s, pos + 1)
	if not from then
		return s
	end
	local to = utf8.offset(s, pos + 2) or (#s + 1)
	return string.sub(s, 1, from - 1) .. string.sub(s, to)
end

-- The UTF-16 offset a field's `cursor` prop wants for a caret after `chars` characters.
local function utf16_at(s: string, chars: number): number
	local units = 0
	local seen = 0
	for _, cp in utf8.codes(s) do
		if seen >= chars then
			break
		end
		units += if cp > 0xFFFF then 2 else 1
		seen += 1
	end
	return units
end

-- Loading ---------------------------------------------------------------------

local function selected_card(state: State): Card?
	local board = state.board
	local column = if board then board.columns[state.col] else nil
	return if column then column.cards[state.row] else nil
end

-- Puts the cursor back on `id` after a reload, or on the first card.
local function place_cursor(state: State, id: string?)
	local board = state.board
	if not board then
		return
	end
	if id then
		for c, column in board.columns do
			for r, card in column.cards do
				if card.id == id then
					state.col, state.row = c, r
					return
				end
			end
		end
	end
	state.col = math.clamp(state.col, 1, math.max(1, #board.columns))
	local here = board.columns[state.col]
	if here and #here.cards > 0 then
		state.row = math.clamp(state.row, 1, #here.cards)
		return
	end
	for c, column in board.columns do
		if #column.cards > 0 then
			state.col, state.row = c, 1
			return
		end
	end
	state.row = 0
end

-- Whether `card` has `who` on it: among the people the view shows, else among
-- any people property.
local function has_person(card: Card, who: string): boolean
	local list: { Person } = card.people
	if #card.assignees > 0 then
		list = card.assignees
	end
	for _, person in list do
		if person.id == who then
			return true
		end
	end
	return false
end

-- Shows only `state.only`'s cards (everyone's when nil), from the full lists
-- kept at load.
local function apply_filter(state: State)
	local board = state.board
	if not board then
		return
	end
	-- Empty columns go when asked to, except while a card is carried: they are
	-- where it might land.
	local hide = state.hide_empty and state.lifted == nil
	local columns: { Column } = {}
	for _, column in state.all_columns do
		local all = state.pool[column.key]
		if all then
			local kept: { Card } = {}
			for _, card in all do
				if not state.only or has_person(card, state.only) then
					table.insert(kept, card)
				end
			end
			column.cards = kept
		end
		if not hide or #column.cards > 0 then
			table.insert(columns, column)
		end
	end
	board.columns = columns
end

-- Lays the columns out again (a filter or the carrying changed which show) and
-- keeps the cursor on its card.
local function relayout(state: State)
	local keep = selected_card(state)
	apply_filter(state)
	place_cursor(state, if keep then keep.id else nil)
end

local function toggle_hide_empty(state: State)
	state.hide_empty = not state.hide_empty
	state.tops = {}
	relayout(state)
end

local function set_only(state: State, who: string?)
	local keep = selected_card(state)
	state.only = who
	state.lifted = nil
	state.tops = {}
	apply_filter(state)
	place_cursor(state, if keep then keep.id else nil)
end

-- The person using this machine: remembered, else the one named like the
-- operating-system user.
local function me(state: State): string?
	local board = state.board
	if not board then
		return nil
	end
	local stored = tern.kv.get("me")
	if type(stored) == "string" then
		for _, person in board.people do
			if person.id == stored then
				return stored
			end
		end
	end
	for _, var in { "USERNAME", "USER", "LOGNAME" } do
		local name = tern.getenv(var)
		if name and name ~= "" then
			for _, person in board.people do
				if string.lower(person.name) == string.lower(name) then
					return person.id
				end
			end
		end
	end
	return nil
end

-- A pick in the people menu. When `m` could not tell who the person is, the
-- first pick is remembered as them.
local function pick_only(state: State, value: string)
	if value == "all" then
		set_only(state, nil)
		return
	end
	if state.learn then
		state.learn = false
		tern.kv.set("me", value)
		state.cx:toast("info", "Remembered as you", "m now shows these cards.")
	end
	set_only(state, value)
end

local function toggle_mine(state: State)
	if state.only then
		set_only(state, nil)
		return
	end
	local who = me(state)
	if who then
		set_only(state, who)
	else
		state.learn = true
		state.cx:toast("info", "Which person are you?", "Pick your name in the people menu; it is remembered as you, and m then shows your cards.")
	end
end

local refresh: (state: State) -> ()

-- The databases the integration can see, read once when a pane has no board.
local function load_boards(state: State)
	local secret = token()
	if not secret or state.boards ~= nil or state.boards_loading then
		return
	end
	state.boards_loading = true
	notion.boards(secret, function(list: { BoardInfo }, _problem)
		state.boards_loading = false
		if alive(state) then
			state.boards = list
			state.pick_at = 1
			local pictures: { string } = {}
			for _, info in list do
				if info.icon and info.icon.url then
					table.insert(pictures, info.icon.url)
				end
			end
			fetch_pictures(state, pictures)
			state.cx:render()
		end
	end)
end

-- The workspace's name, read once, for the title.
local function load_workspace(state: State)
	local secret = token()
	if not secret or state.workspace then
		return
	end
	notion.workspace(secret, function(name: string?)
		if name and alive(state) then
			state.workspace = name
			state.cx:render()
		end
	end)
end

-- Back to the list of databases, to pick another board.
local function choose_board(state: State)
	state.settings = false -- the list is what to look at now
	if state.board and state.ref then
		state.previous = { ref = state.ref, source = state.source }
	elseif state.last_good then
		state.previous = state.last_good
	end
	state.ref = nil
	state.board = nil
	state.panel = false
	state.form = nil
	state.lifted = nil
	state.loading = false
	state.generation += 1
	state.boards = nil
	state.pick_at = 1
	refresh(state)
end

-- Installs the newer version with Tern's own command. When that can't be done
-- (a linked copy, `tern` not found) the command is copied for the person to run.
local function run_update(state: State)
	if state.updating then
		return
	end
	local argv = update.command()
	local line = table.concat(argv, " ")
	local function fallback(why: string)
		state.updating = false
		state.cx:copy(line)
		state.cx:toast("error", "Could not update by itself", why .. " The command is copied: run it in a terminal.")
		state.cx:render()
	end
	state.updating = true
	local ok = pcall(tern.process.run, argv, { timeout_ms = 120000 }, function(result: ProcessResult, _)
		if not alive(state) then
			return
		end
		if result.status == 0 then
			state.updating = false
			state.update = nil
			state.cx:toast("success", "Notion Kanban updated", "The plugin reloads.")
			state.cx:render()
		else
			fallback(string.match(result.stderr, "[^\r\n]+") or ("tern exited with " .. result.status .. "."))
		end
	end)
	if not ok then
		fallback("tern could not be started.")
	end
end

function refresh(state: State)
	if not alive(state) then
		return
	end
	if state.loading then
		state.again = true
		return
	end
	local secret = token()
	if not secret then
		state.problem = { kind = "notoken", text = "Notion needs an integration token." }
		return
	end
	local ref = state.ref
	if not ref then
		state.problem = { kind = "noboard", text = "No board is set for this pane." }
		load_boards(state)
		return
	end
	state.loading = true
	state.generation += 1
	local generation = state.generation
	local keep = selected_card(state)
	local keep_id = if keep then keep.id else nil
	local ok, err = pcall(notion.load, secret, ref, function(board: Board?, problem: Problem?)
		-- A newer refresh or another board (pasted link) supersedes this one.
		if not alive(state) or state.generation ~= generation then
			return
		end
		state.loading = false
		if board then
			state.board = board
			state.problem = nil
			state.fetched = os.time()
			state.last_good = { ref = ref, source = state.source }
			state.details = {}
			state.lifted = nil
			state.pool = {}
			state.all_columns = board.columns
			for _, column in board.columns do
				state.pool[column.key] = column.cards
			end
			apply_filter(state)
			place_cursor(state, keep_id)
			fetch_avatars(state, board)
			if board.icon and board.icon.url then
				fetch_pictures(state, { board.icon.url })
			end
			load_workspace(state)
		else
			state.problem = problem
		end
		state.cx:render()
		if state.again then
			-- Asked for while this read ran (a card moved): its answer may predate that.
			state.again = false
			refresh(state)
		end
	end)
	if not ok then
		state.loading = false
		state.problem = { kind = "failed", text = "Tern could not send the request.", detail = tostring(err) }
	end
end

-- One pending timer per live run, canceled when the run is replaced.
local function poll(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(POLL_MS, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		if state.lifted == nil then
			refresh(state) -- a reload would drop the card being carried
		end
		state.cx:render()
		poll(state)
	end)
end

-- Points the block at another board and loads it.
local function switch_board(state: State, ref: Ref, source: string)
	state.ref = ref
	state.previous = nil
	state.source = source
	state.board = nil
	state.problem = nil
	state.loading = false
	state.generation += 1
	state.col, state.row, state.first, state.tops = 1, 0, 1, {}
	state.panel = false
	state.form = nil
	refresh(state)
end

-- Shows another view of the same database (a sprint board, all tasks) and
-- keeps the old board on screen while it loads.
local function switch_view(state: State, view_id: string)
	local ref = state.ref
	local board = state.board
	if not ref or (board and board.view_id == view_id) then
		return
	end
	state.ref = { database = ref.database, view = view_id }
	state.switched = true
	state.loading = false
	state.generation += 1
	state.tops = {}
	refresh(state)
end

local function cycle_view(state: State, dir: number)
	local board = state.board
	if not board or #board.views < 2 then
		return
	end
	local at = 1
	for i, info in board.views do
		if info.id == board.view_id then
			at = i
		end
	end
	local nxt = board.views[(at - 1 + dir) % #board.views + 1]
	switch_view(state, nxt.id)
end

-- Groups the board by another property (the view's own grouping again when it
-- is the view that changes).
local function switch_group(state: State, name: string)
	local ref = state.ref
	local board = state.board
	if not ref or (board and board.group == name) then
		return
	end
	state.ref = { database = ref.database, view = ref.view, group = name }
	state.switched = true
	state.loading = false
	state.generation += 1
	state.tops = {}
	state.col, state.row = 1, 0
	refresh(state)
end

-- Detail panel -------------------------------------------------------------------

-- Reads the selected card's content once per load.
local function ensure_detail(state: State)
	local card = selected_card(state)
	local secret = token()
	if not state.panel or not card or not secret or state.details[card.id] then
		return
	end
	local id = card.id
	state.details[id] = { markdown = nil, loading = true, problem = nil }
	local generation = state.generation
	local related: { string } = {}
	for _, field in card.fields do
		local ids = field.ids
		if ids then
			for _, page in ids do
				table.insert(related, page)
			end
		end
	end
	if #related > 0 then
		notion.titles(secret, related, function()
			if alive(state) and state.generation == generation then
				state.cx:render()
			end
		end)
	end
	notion.detail(secret, id, function(markdown: string?, problem: Problem?)
		if not alive(state) or state.generation ~= generation then
			return
		end
		if markdown then
			state.details[id] = { markdown = notion_md.from_notion(markdown), loading = false, problem = nil }
		else
			local text = if problem then problem.text .. (if problem.detail then " " .. problem.detail else "") else "Could not read the card."
			state.details[id] = { markdown = nil, loading = false, problem = text }
		end
		state.cx:render()
	end)
end

-- Layout and navigation -----------------------------------------------------------

-- Rows a card takes: its title wrapped to `chars` characters, its other lines,
-- and CARD_CHROME for padding and the gap below. An estimate: Tern's block
-- views cannot measure, so it leans high rather than let a card run past the
-- bottom.
local function card_rows(card: Card, chars: number): number
	local title = if card.title ~= "" then card.title else "Untitled"
	-- Every title sits after an icon, two cells wide.
	local rows = math.max(1, math.ceil(((utf8.len(title) or #title) + 2) / chars))
	local blocks = 1
	if card.parent then
		rows += 1
		blocks += 1
	end
	if #card.assignees > 0 then
		-- Each person: an avatar (two cells), the name, a gap.
		local cells = 0
		for _, person in card.assignees do
			cells += (utf8.len(person.name) or #person.name) + 3
		end
		rows += math.max(1, math.ceil(cells / chars))
		blocks += 1
	end
	if #card.meta > 0 then
		local meta = table.concat(card.meta, "  ·  ")
		rows += math.max(1, math.ceil((utf8.len(meta) or #meta) / chars))
		blocks += 1
	end
	if #card.tags > 0 then
		rows += 1
		blocks += 1
	end
	return rows + CARD_CHROME + CARD_BLOCK_GAP * (blocks - 1)
end

-- The last card of `column` that fits `budget` rows when the column shows from
-- card `top`; rows are kept back for the "N more" lines it needs. Always at
-- least one card.
local function fit(column: Column, top: number, budget: number, chars: number): number
	local count = #column.cards
	local room = budget - (if top > 1 then 1 else 0)
	local used = 0
	local last = top - 1
	for r = top, count do
		local cost = card_rows(column.cards[r], chars)
		local reserve = if r < count then 1 else 0
		if last >= top and used + cost + reserve > room then
			break
		end
		used += cost
		last = r
	end
	return last
end

-- How many columns fit, the rows a column has for cards, and the characters a
-- card title fits on one line.
local function capacity(state: State): (number, number, number)
	local width = if state.panel then state.cx.cols * (1 - PANEL_SHARE) else state.cx.cols
	local columns = math.max(1, math.floor(width / COLUMN_CELLS))
	local board = state.board
	local across = if board then math.max(1, math.min(columns, #board.columns)) else columns
	local chars = math.max(8, math.floor((width / across - CARD_SIDE_CELLS) / TITLE_CELLS))
	local dock = 1
	if board then
		for _, shown in { state.problem ~= nil, board.filter_dropped, board.truncated, board.note ~= nil, state.update ~= nil, state.update ~= nil } do
			if shown then
				dock += 1
			end
		end
	end
	local budget = math.max(3, state.cx.rows - CHROME_ROWS - dock)
	return columns, budget, chars
end

-- Scrolls the column strip and the selected column to keep the cursor in sight.
local function reveal(state: State)
	local board = state.board
	if not board then
		return
	end
	local columns, budget, chars = capacity(state)
	local n = #board.columns
	if state.col < state.first then
		state.first = state.col
	elseif state.col >= state.first + columns then
		state.first = state.col - columns + 1
	end
	state.first = math.clamp(state.first, 1, math.max(1, n - columns + 1))
	local column = board.columns[state.col]
	if column and state.row > 0 then
		local top = math.clamp(state.tops[column.key] or 1, 1, #column.cards)
		if state.row < top then
			top = state.row
		else
			while top < state.row and fit(column, top, budget, chars) < state.row do
				top += 1
			end
		end
		state.tops[column.key] = top
	end
end

local function move_row(state: State, to: number)
	local board = state.board
	local column = if board then board.columns[state.col] else nil
	if column and #column.cards > 0 then
		state.row = math.clamp(to, 1, #column.cards)
	end
end

-- Moves to the nearest column with cards in direction `dir`; empty ones are skipped.
local function move_col(state: State, dir: number)
	local board = state.board
	if not board then
		return
	end
	local c = state.col + dir
	while c >= 1 and c <= #board.columns do
		local column = board.columns[c]
		if #column.cards > 0 then
			state.col = c
			state.row = math.clamp(math.max(state.row, 1), 1, #column.cards)
			return
		end
		c += dir
	end
end

local function select_id(state: State, id: string): boolean
	local board = state.board
	if not board then
		return false
	end
	for c, column in board.columns do
		for r, card in column.cards do
			if card.id == id then
				state.col, state.row = c, r
				return true
			end
		end
	end
	return false
end

local function open_selected(state: State, cx: BlockCx)
	local card = selected_card(state)
	if card then
		cx:open(card.url)
	end
end

local function open_board(state: State, cx: BlockCx)
	local board = state.board
	if board then
		local url = board.view_url or board.url
		if url then
			cx:open(url)
		end
	end
end

local function problem_text(problem: Problem): string
	if problem.detail and problem.detail ~= "" then
		return problem.text .. " " .. problem.detail
	end
	return problem.text
end

-- Moves a card to column number `to`: shown at once, written to Notion, and
-- put back by a refresh if Notion refuses.
local function move_card(state: State, card_id: string, to: number)
	local board = state.board
	local secret = token()
	local target = if board then board.columns[to] else nil
	if not board or not secret or not target then
		return
	end
	if not target.option then
		state.cx:toast("error", "Can't move there", "“" .. target.name .. "” has no value to write.")
		return
	end
	local ordered: { Column } = {}
	local here = board.columns[state.col]
	if here then
		table.insert(ordered, here)
	end
	for _, column in board.columns do
		table.insert(ordered, column)
	end
	for _, column in ordered do
		for i, card in column.cards do
			if card.id == card_id then
				if column == target then
					return
				end
				table.remove(column.cards, i)
				table.insert(target.cards, 1, card)
				-- The full lists the filter works from follow the move.
				local from_all, to_all = state.pool[column.key], state.pool[target.key]
				if from_all then
					local at = table.find(from_all, card)
					if at then
						table.remove(from_all, at)
					end
				end
				if to_all then
					table.insert(to_all, 1, card)
				end
				state.col, state.row = to, 1
				local generation = state.generation
				local option: string = target.option :: string
				notion.move(secret, board, card, column.option, option, function(problem: Problem?)
					if not alive(state) then
						return
					end
					if problem then
						state.cx:toast("error", "Notion did not move the card", problem_text(problem))
					end
					-- Either way, read the board again: it puts back a refused
					-- move and shows the card where Notion placed it.
					refresh(state)
					state.cx:render()
				end)
				return
			end
		end
	end
end

-- The column to move the selected card into, `dir` away, skipping columns with
-- no value to write.
local function move_selected(state: State, dir: number)
	local board = state.board
	local card = selected_card(state)
	if not board or not card then
		return
	end
	local c = state.col + dir
	while c >= 1 and c <= #board.columns do
		if board.columns[c].option then
			move_card(state, card.id, c)
			return
		end
		c += dir
	end
end

-- Pick up and drop -----------------------------------------------------------------
-- Tern's views send no pointer-drag events, so a move by hand is a pick-up
-- (Space, or the card's menu) and a drop (Enter, or a click on the column).

-- The index of the column holding card `id`.
local function column_of(board: Board, id: string): number?
	for c, column in board.columns do
		for _, card in column.cards do
			if card.id == id then
				return c
			end
		end
	end
	return nil
end

-- The next column in direction `dir` the lifted card could drop into.
local function target_step(state: State, dir: number)
	local board = state.board
	local from = if board and state.lifted then column_of(board, state.lifted) else nil
	if not board or not from then
		return
	end
	local c = state.target + dir
	while c >= 1 and c <= #board.columns do
		if board.columns[c].option and c ~= from then
			state.target = c
			return
		end
		c += dir
	end
end

local function lift_selected(state: State)
	local card = selected_card(state)
	if not card then
		return
	end
	state.lifted = card.id
	relayout(state) -- every column shows while a card is carried
	state.target = state.col
	target_step(state, 1)
	if state.target == state.col then
		target_step(state, -1)
	end
end

local function drop_lifted(state: State)
	local id = state.lifted
	state.lifted = nil
	if id and state.board and state.board.columns[state.target] then
		move_card(state, id, state.target)
	end
	relayout(state)
end

-- The new-card form -------------------------------------------------------------

-- Columns a card can be created in, empty ones included.
local function form_columns(state: State, board: Board): { Column }
	local out: { Column } = {}
	for _, column in state.all_columns do
		if column.option then
			table.insert(out, column)
		end
	end
	return out
end

-- Everyone known: people on the cards, then the workspace's.
local function form_people(state: State, board: Board): { Person }
	local out: { Person } = {}
	local seen: { [string]: boolean } = {}
	for _, list in { board.people, state.users } do
		for _, person in list do
			if not seen[person.id] then
				seen[person.id] = true
				table.insert(out, person)
			end
		end
	end
	table.sort(out, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return out
end

-- The sprint a new card starts in: the current one.
local function default_sprint(board: Board): string?
	for _, sprint in board.sprints do
		if string.lower(sprint.state or "") == "current" then
			return sprint.id
		end
	end
	return nil
end

local function open_form(state: State, cx: BlockCx)
	local board = state.board
	if not board then
		return
	end
	local columns = form_columns(state, board)
	if #columns == 0 then
		cx:toast("error", "Can't make a card here", "This board has no column to write.")
		return
	end
	local here = board.columns[state.col]
	local column = columns[1].key
	if here and here.option then
		column = here.key
	end
	state.form = {
		name = "",
		cursor = 0,
		field = "name",
		picks = { column = column, sprint = default_sprint(board) or "none", parent = "none", person = "none" },
		touched = {},
		picking = nil,
		query = "",
		at = 1,
		busy = false,
		error = nil,
	}
	cx:frame({ { "focus", "layer.form.name" } })
	local secret = token()
	if secret and #state.users == 0 then
		notion.users(secret, function(list: { Person })
			if alive(state) then
				state.users = list
				state.cx:render()
			end
		end)
	end
end

local function submit_form(state: State, cx: BlockCx)
	local form = state.form
	local board = state.board
	local secret = token()
	if not form or not board or not secret then
		return
	end
	local title = string.match(form.name, "^%s*(.-)%s*$") or ""
	if title == "" then
		form.error = "Give the card a name."
		return
	end
	local option: string? = nil
	for _, column in board.columns do
		if column.key == form.picks.column then
			option = column.option
		end
	end
	form.busy = true
	form.error = nil
	local generation = state.generation
	notion.create(secret, board, {
		title = title,
		option = option,
		parent_id = if form.picks.parent ~= "none" then form.picks.parent else nil,
		person_id = if form.picks.person ~= "none" then form.picks.person else nil,
		sprint_id = if form.picks.sprint ~= "none" then form.picks.sprint else nil,
	}, function(problem: Problem?)
		if not alive(state) or state.generation ~= generation then
			return
		end
		form.busy = false
		if problem then
			form.error = problem_text(problem)
		else
			state.form = nil
			cx:toast("success", "Card created", title)
			refresh(state)
		end
		state.cx:render()
	end)
end

-- The fields the form shows, in the order Tab visits them.
local function form_fields(board: Board): { string }
	local out = { "name", "column" }
	if board.sprint_prop and board.sprint_prop ~= board.group then
		table.insert(out, "sprint")
	end
	if board.parent_prop and board.parent_prop ~= board.group then
		table.insert(out, "parent")
	end
	if board.people_prop and board.people_prop ~= board.group then
		table.insert(out, "person")
	end
	return out
end

-- What a select field can be set to.
local function field_choices(state: State, board: Board, field: string): { Choice }
	local out: { Choice } = {}
	if field == "column" then
		for _, column in form_columns(state, board) do
			table.insert(out, { value = column.key, label = column.name })
		end
	elseif field == "sprint" then
		table.insert(out, { value = "none", label = "No sprint" })
		for _, sprint in board.sprints do
			table.insert(out, { value = sprint.id, label = sprint.name, detail = sprint.state })
		end
	elseif field == "parent" then
		table.insert(out, { value = "none", label = "No parent" })
		for _, parent in board.parents do
			table.insert(out, { value = parent.id, label = parent.name })
		end
	elseif field == "person" then
		table.insert(out, { value = "none", label = "Unassigned" })
		for _, person in form_people(state, board) do
			table.insert(out, { value = person.id, label = person.name })
		end
	end
	return out
end

local function set_pick(form: Form, field: string, value: string)
	form.picks[field] = value
	form.touched[field] = true
	form.field = field
end

local function cycle_field(state: State, board: Board, form: Form, dir: number)
	local choices = field_choices(state, board, form.field)
	if #choices == 0 then
		return
	end
	local current = form.picks[form.field]
	local at = 1
	for i, choice in choices do
		if choice.value == current then
			at = i
		end
	end
	set_pick(form, form.field, choices[(at - 1 + dir) % #choices + 1].value)
end

local function focus_field(form: Form, field: string, cx: BlockCx)
	form.field = field
	if field == "name" then
		cx:frame({ { "focus", "layer.form.name" } })
	end
end

local function step_field(board: Board, form: Form, dir: number, cx: BlockCx)
	local order = form_fields(board)
	local at = 1
	for i, field in order do
		if field == form.field then
			at = i
		end
	end
	focus_field(form, order[(at - 1 + dir) % #order + 1], cx)
end

-- The choices the open list shows: those whose label has the typed query.
local function visible_choices(state: State, board: Board, form: Form): { Choice }
	local all = field_choices(state, board, form.picking or form.field)
	if form.query == "" then
		return all
	end
	local wanted = string.lower(form.query)
	local out: { Choice } = {}
	for _, choice in all do
		if string.find(string.lower(choice.label), wanted, 1, true) then
			table.insert(out, choice)
		end
	end
	return out
end

local function open_picker(state: State, board: Board, form: Form, field: string, cx: BlockCx)
	if field == "name" then
		return
	end
	local choices = field_choices(state, board, field)
	form.field = field
	form.picking = field
	form.query = ""
	form.at = 1
	for i, choice in choices do
		if choice.value == form.picks[field] then
			form.at = i
		end
	end
	if #choices > PICKER_SEARCH_FROM then
		cx:frame({ { "focus", "layer.form.query" } })
	end
end

-- Sets the open list's `index`th visible choice and goes back to the form.
local function choose_pick(state: State, board: Board, form: Form, index: number, cx: BlockCx)
	local field = form.picking
	if not field then
		return
	end
	local choice = visible_choices(state, board, form)[index]
	if choice then
		set_pick(form, field, choice.value)
	end
	form.picking = nil
	form.query = ""
	focus_field(form, field, cx)
end

local function form_paste(form: Form, text: string)
	local line = string.gsub(text, "[\r\n]+", " ")
	if utf8.len(line) then
		form.name = insert_at(form.name, form.cursor, line)
		form.cursor += char_count(line)
	end
end

local function form_key(state: State, key: Key, cx: BlockCx)
	local form = state.form :: Form
	local board = state.board :: Board
	if form.busy then
		return
	end
	form.error = nil
	local name = key.name
	if form.picking then
		-- A list is open: keys search and choose in it; Esc goes back to the form.
		local shown = visible_choices(state, board, form)
		if name == "escape" then
			form.picking = nil
			form.query = ""
		elseif name == "enter" then
			choose_pick(state, board, form, form.at, cx)
		elseif name == "up" then
			form.at = math.max(1, form.at - 1)
		elseif name == "down" then
			form.at = math.min(math.max(1, #shown), form.at + 1)
		elseif name == "backspace" then
			if form.query ~= "" then
				form.query = delete_at(form.query, char_count(form.query) - 1)
				form.at = 1
			end
		elseif key.text and key.text ~= "" and utf8.len(key.text) and not key.ctrl and not key.alt and not key.meta then
			form.query ..= string.gsub(key.text, "[\r\n]+", " ")
			form.at = 1
		end
		return
	end
	if name == "escape" then
		state.form = nil
	elseif name == "enter" then
		submit_form(state, cx)
	elseif name == "tab" then
		step_field(board, form, if key.shift then -1 else 1, cx)
	elseif name == "up" then
		step_field(board, form, -1, cx)
	elseif name == "down" then
		step_field(board, form, 1, cx)
	elseif form.field == "name" then
		if name == "left" then
			form.cursor = math.max(0, form.cursor - 1)
		elseif name == "right" then
			form.cursor = math.min(char_count(form.name), form.cursor + 1)
		elseif name == "home" then
			form.cursor = 0
		elseif name == "end" then
			form.cursor = char_count(form.name)
		elseif name == "backspace" then
			if form.cursor > 0 then
				form.name = delete_at(form.name, form.cursor - 1)
				form.cursor -= 1
			end
		elseif name == "delete" then
			form.name = delete_at(form.name, form.cursor)
		elseif key.text and not key.ctrl and not key.alt and not key.meta then
			form_paste(form, key.text)
		end
	else
		if name == "left" then
			cycle_field(state, board, form, -1)
		elseif name == "space" then
			open_picker(state, board, form, form.field, cx)
		elseif name == "right" then
			cycle_field(state, board, form, 1)
		end
	end
end

-- Views -------------------------------------------------------------------------

local function clicking(node: Node, act: string, key: string?): Node
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	p.key = key
	node.p = p
	return node
end

-- Where Esc goes from a screen with no board: the board left to pick another,
-- else the last one that loaded (when this is not it).
local function back_target(state: State): { ref: Ref, source: string }?
	if state.previous then
		return state.previous
	end
	local good = state.last_good
	if good and not (state.ref and state.ref.database == good.ref.database and state.ref.view == good.ref.view) then
		return good
	end
	return nil
end

local function go_back(state: State): boolean
	local back = back_target(state)
	if not back then
		return false
	end
	switch_board(state, back.ref, back.source)
	return true
end

-- A database's logo: its emoji, its picture once fetched, else `default` (a
-- Tern icon name), else nothing. Whatever it is, it sits centered in a slot of
-- one width, so the names after it line up. `click` replaces the picture's
-- zoom on click; `size` is the picture's side in pixels.
local function icon_node(state: State, icon: Icon?, default: string?, click: string?, size: number?, slot_width: string?): Node?
	local inner: Node? = nil
	if icon then
		if icon.emoji then
			local emoji = ui.text({ icon.emoji })
			local p: { [string]: any } = emoji.p or {}
			p.role = "notion.emoji-" .. (size or 18)
			emoji.p = p
			inner = emoji
		else
			local blob = if icon.url then state.avatars[picture_key(icon.url)] else nil
			if blob then
				local side = size or 18
				inner = ui.node("image", { blob = blob, w = side, h = side, alt = "", role = "notion.logo", actions = { click = click or "none" } })
			end
		end
	end
	if not inner and default then
		inner = ui.node("icon", { name = default, tone = "muted", role = "notion.glyph-" .. (size or 18) })
	end
	if not inner then
		return nil
	end
	local slot = slot_width or (if size and size > 20 then "4ch" else "3ch")
	return ui.node("row", { min = { w = slot }, max = { w = slot }, shrink = 0, justify = "center", align = "center" }, { inner })
end

local function problem_view(state: State, problem: Problem): Node
	local heads: { [string]: string } = {
		notoken = "Connect Notion",
		noboard = "Choose a Notion board",
		network = "Could not reach Notion",
		auth = "Notion rejected the token",
		forbidden = "Notion denied access",
		notfound = "Board not found",
		rate = "Notion is busy",
		nogroup = "No columns to show",
		failed = "Could not load the board",
	}
	local help: { [string]: string } = {
		notoken = "Create an internal integration at [notion.so/profile/integrations](https://www.notion.so/profile/integrations), "
			.. "then **paste its token here**. Or set `NOTION_TOKEN` on the machine that runs your panes.",
		noboard = "**Paste a link** to the Notion database here (copy it from a board view's address bar). "
			.. "To bind this project instead, put the link in `.tern/notion.json`:\n\n"
			.. '```json\n{ "board": "https://www.notion.so/…?v=…" }\n```',
		auth = "**Paste a new token** here, or fix `NOTION_TOKEN`.",
		notfound = "Open the database in Notion, then **••• › Connections** and add your integration. "
			.. "Or **paste another link** here.",
		forbidden = "In the integration's settings, turn on the **Read content** capability.",
		nogroup = "Boards need a Status or Select property. **Paste another link** to show a different database.",
	}
	local text = problem.text .. " " .. (help[problem.kind] or "Press **r** to try again.")
	-- With a token and no board, offer the databases the integration can see.
	local listing = problem.kind == "noboard" and token() ~= nil and not problem.detail
	local boards = state.boards
	if listing then
		if boards == nil then
			text = problem.text .. " Looking for your databases…"
		elseif #boards == 0 then
			text = problem.text
				.. " This integration can't see a database yet: in Notion, open it, then **••• › Connections** and add the integration. Or **paste a link**."
		else
			text = problem.text .. " **Choose a database** below, or **paste a link**."
		end
	end
	local children: { Node } = { ui.md(text) }
	local settings_in_row = false
	if listing and boards then
		if #boards > 0 then
			-- The pane does not scroll, so only the rows around the highlighted one
			-- are drawn, with a count of those above and below.
			local visible = math.max(4, math.min(12, state.cx.rows - 12))
			local first = math.clamp(state.pick_at - visible // 2, 1, math.max(1, #boards - visible + 1))
			local last = math.min(#boards, first + visible - 1)
			local rows: { Node } = {}
			if first > 1 then
				table.insert(rows, ui.text({ ui.span("↑ " .. (first - 1) .. " more", "dim") }))
			end
			for i = first, last do
				local info = boards[i]
				local pick = "board-pick=" .. i
				table.insert(
					rows,
					ui.node("row", {
						key = "b" .. i,
						role = "notion.board",
						tone = if i == state.pick_at then "accent" else nil,
						gap = "sm",
						align = "center",
						actions = { click = pick },
					}, {
						icon_node(state, info.icon, "database", pick, 20) :: Node,
						ui.text({ ui.span(info.name) }),
						ui.text({ ui.span(info.project or state.workspace or "", "muted") }),
					})
				)
			end
			if last < #boards then
				table.insert(rows, ui.text({ ui.span("↓ " .. (#boards - last) .. " more", "dim") }))
			end
			table.insert(children, ui.node("col", { key = "boards" }, rows))
		end
		local row: { Node } = {
			ui.button("Refresh list", { size = "sm", icon = "repeat", variant = "quiet", title = "Read the databases again (r)", actions = { click = "boards-refresh" } }),
		}
		if back_target(state) then
			table.insert(row, ui.button("Back to the board", { size = "sm", variant = "quiet", keys = { "esc" }, actions = { click = "board-back" } }))
		end
		table.insert(row, ui.button("Settings", { size = "sm", icon = "gear", variant = "quiet", title = "Plugin settings (,)", actions = { click = "settings" } }))
		settings_in_row = true
		table.insert(children, ui.row(row))
	end
	if problem.detail and problem.detail ~= "" then
		table.insert(children, ui.code(problem.detail))
	end
	local buttons: { Node } = {}
	if problem.kind ~= "notoken" and problem.kind ~= "noboard" then
		table.insert(buttons, clicking(ui.badge("Retry", "accent"), "retry", "retry"))
		table.insert(buttons, ui.button("Choose another board", { size = "sm", variant = "quiet", actions = { click = "change-board" } }))
		if back_target(state) then
			table.insert(buttons, ui.button("Back", { size = "sm", variant = "quiet", keys = { "esc" }, actions = { click = "board-back" } }))
		end
	end
	-- Settings is reachable from every screen, the ones that most need it included.
	if not settings_in_row then
		table.insert(buttons, ui.button("Settings", { size = "sm", icon = "gear", variant = "quiet", title = "Plugin settings (,)", actions = { click = "settings" } }))
	end
	table.insert(children, ui.row(buttons))
	local card = ui.node("card", {
		key = "problem",
		head = { ui.span(heads[problem.kind] or "Notion", "strong") },
		tone = if problem.kind == "notoken" or problem.kind == "noboard" then "accent" else "error",
	}, children)
	return ui.col({ card })
end

-- `node` sharing a row's width with its siblings: it takes what they leave.
local function growing(node: Node): Node
	local p: { [string]: any } = node.p or {}
	p.grow, p.basis = 1, 0
	node.p = p
	return node
end

local function card_node(state: State, board: Board, card: Card, column: Column, selected: boolean): Node
	local title = if card.title ~= "" then card.title else "Untitled"
	local body: { Node } = {}
	if card.parent then
		-- Like Notion: a small up arrow, the parent's title, both greyed.
		local name = growing(ui.text({ ui.span(card.parent, "dim") }))
		table.insert(body, ui.node("row", { gap = "xs", align = "center" }, { ui.node("icon", { name = "arrow-up", tone = "muted" }), name }))
	end
	-- The page's icon (emoji, built-in or picture), or a file glyph when it has none.
	local lead: Node = icon_node(state, card.icon, "doc", "pick=" .. card.id, 16, "2ch") :: Node
	local name = growing(ui.text({ ui.span(title, if card.title ~= "" then "strong" else "muted") }))
	table.insert(body, ui.node("row", { gap = "xs", align = "start" }, { lead, name }))
	if #card.assignees > 0 then
		local who: { Node } = {}
		for _, person in card.assignees do
			local blob = if person.avatar then state.avatars[picture_key(person.avatar)] else nil
			table.insert(
				who,
				ui.node("row", { gap = "xs", align = "center" }, {
					ui.node("avatar", { text = person.name, seed = person.id, size = "xs", blob = blob }),
					ui.text({ ui.span(person.name, "muted") }),
				})
			)
		end
		table.insert(body, ui.node("row", { gap = "sm", align = "center", wrap = true }, who))
	end
	if #card.meta > 0 then
		table.insert(body, ui.text({ ui.span(table.concat(card.meta, "  ·  "), "muted") }))
	end
	if #card.tags > 0 then
		local tags: { Node } = {}
		for i, tag in card.tags do
			if i > MAX_TAGS then
				table.insert(tags, ui.badge("+" .. (#card.tags - MAX_TAGS), "muted"))
				break
			end
			table.insert(tags, ui.badge(tag.text, tag.tone))
		end
		table.insert(body, ui.node("row", { gap = "xs", wrap = true }, tags))
	end
	local menu: { any } = { { header = "Move to" } }
	for _, other in board.columns do
		if other ~= column and other.option then
			table.insert(menu, { id = "move=" .. card.id .. "|" .. other.key, label = other.name })
		end
	end
	table.insert(menu, "-")
	table.insert(menu, { id = "lift=" .. card.id, label = "Pick up to move" })
	table.insert(menu, { id = "panel=" .. card.id, label = "Open details", icon = "doc" })
	table.insert(menu, { id = "browser=" .. card.id, label = "Open in browser", icon = "globe" })
	return ui.node("card", {
		key = card.id,
		role = "notion.card",
		tone = if state.lifted == card.id then "warning" elseif selected and not state.lifted then "accent" else nil,
		actions = { click = "pick=" .. card.id, dblclick = "panel=" .. card.id, menu = menu },
	}, body)
end

local function column_node(state: State, board: Board, index: number, budget: number, chars: number): Node
	local column = board.columns[index]
	local top = math.clamp(state.tops[column.key] or 1, 1, math.max(1, #column.cards))
	local last = fit(column, top, budget, chars)
	local children: { Node } = {
		ui.node("row", { key = "head", gap = "sm" }, {
			ui.badge(column.name, column.tone),
			ui.text({ ui.span(tostring(#column.cards), "muted") }),
		}),
	}
	if top > 1 then
		table.insert(children, ui.text({ ui.span("↑ " .. (top - 1) .. " more", "dim") }))
	end
	for r = top, last do
		table.insert(children, card_node(state, board, column.cards[r], column, index == state.col and r == state.row))
	end
	if last < #column.cards then
		table.insert(children, ui.text({ ui.span("↓ " .. (#column.cards - last) .. " more", "dim") }))
	end
	if #column.cards == 0 then
		table.insert(children, ui.text({ ui.span("No cards", "dim") }))
	end
	local props: { [string]: any } = { key = column.key, gap = "sm", grow = 1, basis = 0, min = { w = "18ch" } }
	if state.lifted and column.option and column_of(board, state.lifted) ~= index then
		-- Carrying a card: this column can take it. The column itself is the
		-- drop zone (a dashed outline, filled while chosen), so nothing moves.
		local chosen = index == state.target
		props.role = if chosen then "notion.target" else "notion.zone"
		props.actions = { click = "drop=" .. column.key }
		if chosen then
			local head = children[1].c :: { Node }
			table.insert(head, ui.text({ ui.span("⏎ drop here", "accent") }))
		end
	end
	return ui.node("col", props, children)
end

local function head_view(state: State, board: Board): Node
	local title: { Span | string } = { ui.span(board.title, "title") }
	local where = board.project or state.workspace
	if where then
		table.insert(title, ui.span(" - " .. where, "muted"))
	end
	local shown = 0
	for _, column in board.columns do
		shown += #column.cards
	end
	table.insert(title, ui.span("  " .. (if state.only then shown .. " of " .. board.total else tostring(board.total)) .. " cards", "muted"))
	if state.loading then
		table.insert(title, ui.span("  refreshing…", "muted"))
	elseif state.fetched then
		table.insert(title, ui.span("  updated " .. os.date("%H:%M", state.fetched), "muted"))
	end
	-- Top row: what the person can do with the board.
	local actions: { Node } = {
		ui.button("Boards", { key = "change-board", size = "sm", icon = "swap", variant = "quiet", title = "Pick another board (B)", actions = { click = "change-board" } }),
		ui.button("Open in Notion", { key = "board", size = "sm", icon = "globe", variant = "quiet", actions = { click = "board" } }),
		ui.button("Settings", { key = "settings", size = "sm", icon = "gear", variant = "quiet", title = "Plugin settings (,)", actions = { click = "settings" } }),
		ui.button("New", { key = "new", size = "sm", icon = "plus", keys = { "n" }, actions = { click = "new" } }),
		ui.button("Refresh", {
			key = "refresh",
			size = "sm",
			icon = "repeat",
			keys = { "r" },
			busy = state.loading,
			actions = { click = "refresh" },
		}),
	}
	-- Second row: how the board is shown, each control named.
	local options: { Node } = {}
	if #board.views > 1 then
		local choices: { any } = {}
		for _, info in board.views do
			table.insert(choices, { value = info.id, label = info.name })
		end
		table.insert(options, ui.node("select", { key = "view", variant = "quiet", size = "sm", label = "View", value = board.view_id, options = choices, title = "View (v)" }))
	elseif board.view_name then
		table.insert(options, ui.text({ ui.span("View  ", "muted"), ui.span(board.view_name) }))
	end
	if #board.groupable > 1 then
		local choices: { any } = {}
		for _, item in board.groupable do
			table.insert(choices, { value = item.name, label = item.name })
		end
		table.insert(options, ui.node("select", { key = "group", variant = "quiet", size = "sm", label = "Group by", value = board.group, options = choices, title = "Group by" }))
	end
	if #board.people > 0 then
		local choices: { any } = { { value = "all", label = "Everyone" } }
		for _, person in board.people do
			table.insert(choices, { value = person.id, label = person.name })
		end
		table.insert(options, ui.node("select", { key = "only", variant = "quiet", size = "sm", label = "Show", value = state.only or "all", options = choices, title = "Whose cards (m: mine)" }))
	end
	table.insert(
		options,
		ui.button("Hide empty", {
			key = "hide-empty",
			size = "sm",
			icon = "eye-off",
			variant = if state.hide_empty then "primary" else "quiet",
			title = if state.hide_empty then "Show empty columns (e)" else "Hide empty columns (e)",
			actions = { click = "hide-empty" },
		})
	)
	local heading: { Node } = {}
	local logo = icon_node(state, board.icon, nil, "none", 24)
	if logo then
		table.insert(heading, logo)
	end
	table.insert(heading, ui.text(title))
	return ui.col({
		ui.node("row", { key = "head", justify = "between", align = "center", wrap = true, gap = "sm" }, {
			ui.node("row", { key = "title", gap = "sm", align = "center" }, heading),
			ui.node("row", { key = "tools", gap = "sm", wrap = true, align = "center" }, actions),
		}),
		ui.node("row", { key = "options", gap = "sm", wrap = true, align = "center" }, options),
	})
end

local function board_view(state: State, board: Board): Node
	reveal(state)
	local columns, budget, chars = capacity(state)
	local shown: { Node } = {}
	for i = state.first, math.min(#board.columns, state.first + columns - 1) do
		table.insert(shown, column_node(state, board, i, budget, chars))
	end
	local children: { Node } = { head_view(state, board) }
	if #board.columns == 0 then
		table.insert(children, ui.text({ ui.span("This database has no “" .. board.group .. "” options to make columns from.", "muted") }))
	else
		table.insert(children, ui.node("row", { key = "columns", gap = "md", align = "start" }, shown))
	end
	local root = ui.col(children)
	if state.panel then
		-- Share the width with the panel beside it.
		local p: { [string]: any } = root.p or {}
		p.grow, p.basis, p.min = 1, 0, { w = "30ch" }
		root.p = p
	end
	return root
end

local function dock_view(state: State, board: Board): Node
	local lines: { Node } = {}
	local problem = state.problem
	if problem then
		table.insert(lines, ui.text({ ui.span(problem.text, "warning"), ui.span("  showing the last read", "muted") }))
	end
	if board.filter_dropped then
		table.insert(
			lines,
			ui.text({ ui.span("Notion would not apply this view's filter here, so every row shows. Press v for another view.", "warning") })
		)
	end
	if board.truncated then
		table.insert(lines, ui.text({ ui.span("Showing the first " .. board.total .. " cards.", "warning") }))
	end
	if board.note then
		table.insert(lines, ui.text({ ui.span(board.note, "muted") }))
	end
	local columns = capacity(state)
	local hint = "←→ column  ↑↓ card  ⏎ details  space pick up  o browser  m mine  n new  v view  r refresh  , settings"
	if state.lifted then
		hint = "Carrying a card: ←→ choose a column  ⏎ or click to drop  esc cancel"
	end
	if #board.columns > columns then
		hint = "column " .. state.col .. "/" .. #board.columns .. "  " .. hint
	end
	table.insert(lines, ui.text({ ui.span(hint, "dim") }))
	local children: { Node } = { ui.lines(lines) }
	if state.update then
		table.insert(
			children,
			ui.node("row", { key = "update", gap = "sm", align = "center" }, {
				ui.text({ ui.span("Notion Kanban " .. state.update .. " is available (you have " .. state.installed .. ").", "accent") }),
				ui.button("Update", { size = "sm", variant = "primary", busy = state.updating, actions = { click = "update" } }),
				ui.button("Later", { size = "sm", variant = "quiet", actions = { click = "update-later" } }),
			})
		)
	end
	return ui.col(children)
end

-- `text` as spans with its web addresses made links (clicking one opens it).
local function linkify(text: string): { Span | string }
	local out: { Span | string } = {}
	local pos = 1
	while true do
		local from, to = string.find(text, "https?://[^%s<>\"')%]]+", pos)
		if not from then
			break
		end
		local url = string.sub(text, from, to)
		url = string.gsub(url, "[%.,;:!?]+$", "")
		if from > pos then
			table.insert(out, string.sub(text, pos, from - 1))
		end
		local shown = string.gsub(string.gsub(url, "^https?://", ""), "^www%.", "")
		if #shown > 48 then
			shown = string.sub(shown, 1, 47) .. "…"
		end
		table.insert(out, ui.link(shown, url))
		pos = from + #url
	end
	if pos <= #text then
		table.insert(out, string.sub(text, pos))
	end
	return out
end

-- The selected card's panel: its properties and its content.
local function panel_view(state: State, board: Board): Node?
	local card = selected_card(state)
	local column = board.columns[state.col]
	if not card or not column then
		return nil
	end
	local rows: { { any } } = { { board.group, column.name } }
	for _, field in card.fields do
		local pair: { any } = { field.name, linkify(notion.field_text(field)) }
		table.insert(rows, pair)
	end
	local detail = state.details[card.id]
	local content: Node
	if detail and detail.markdown and detail.markdown ~= "" then
		content = ui.md(detail.markdown)
	elseif detail and detail.problem then
		content = ui.text({ ui.span(detail.problem, "warning") })
	elseif detail and detail.loading then
		content = ui.text({ ui.span("Loading the card…", "muted") })
	else
		content = ui.text({ ui.span("This card has no content.", "muted") })
	end
	local title = if card.title ~= "" then card.title else "Untitled"
	if card.icon and card.icon.emoji then
		title = card.icon.emoji .. " " .. title
	end
	return ui.node("card", {
		key = "detail",
		role = "notion.panel",
		head = { ui.span(title, "strong") },
		grow = 0,
		shrink = 0,
		basis = PANEL_SHARE,
	}, {
		-- The board does not scroll, so the panel's body does, within the pane.
		ui.node("scroll", { key = "body", gap = "sm", max = { h = math.max(6, state.cx.rows - 14) .. "lines" } }, { ui.kv(rows), content }),
		ui.node("row", { key = "foot", gap = "sm", justify = "end" }, {
			ui.button("Close", { size = "sm", variant = "quiet", keys = { "esc" }, actions = { click = "panel-close" } }),
			ui.button("Open in browser", { size = "sm", keys = { "o" }, actions = { click = "browser" } }),
		}),
	})
end

local ROW_ICONS: { [string]: string } = { column = "kanban", sprint = "timer", parent = "arrow-up", person = "user" }

local function form_view(state: State, board: Board, form: Form): Node
	local labels: { [string]: string } = {
		column = board.group,
		sprint = board.sprint_prop or "Sprint",
		parent = board.parent_prop or "Parent",
		person = "Assignee",
	}
	local picking = form.picking
	if picking then
		-- Choosing a value: its own list (searchable when long) in place of the
		-- form, so nothing opens past the edge of the window.
		local all = field_choices(state, board, picking)
		local shown = visible_choices(state, board, form)
		local items: { Node } = {}
		for i, choice in shown do
			table.insert(
				items,
				ui.node("item", {
					key = "c" .. i,
					label = choice.label,
					detail = choice.detail,
					icon = if form.picks[picking] == choice.value then "check" else nil,
					actions = { click = "form-choose=" .. i },
				})
			)
		end
		local body: { Node } = {}
		if #all > PICKER_SEARCH_FROM then
			table.insert(
				body,
				ui.node("input", {
					key = "query",
					text = form.query,
					cursor = utf16_at(form.query, char_count(form.query)),
					placeholder = "Search " .. string.lower(labels[picking]),
				})
			)
		end
		table.insert(
			body,
			ui.node("list", {
				key = "pick",
				selected = if #shown > 0 then "layer.form.pick.c" .. form.at else nil,
				filter = form.query,
				empty = { ui.span("Nothing matches", "muted") },
				max = { lines = 9 },
			}, items)
		)
		table.insert(
			body,
			ui.node("row", { key = "foot", gap = "md", justify = "between", align = "center" }, {
				ui.text({ ui.span("↑↓ choose  ⏎ select  esc back", "dim") }),
				ui.button("Back", { variant = "quiet", actions = { click = "form-back" } }),
			})
		)
		return ui.node("overlay", { key = "form", modal = true, size = "md", head = labels[picking], meta = board.title, icon = ROW_ICONS[picking], foot = "layer.form.foot" }, body)
	end
	-- One property: its icon and name on the left, its value (a button that opens
	-- the list) on the right.
	local function row(field: string): Node
		local active = form.field == field
		local current = ""
		for _, choice in field_choices(state, board, field) do
			if choice.value == form.picks[field] then
				current = choice.label
			end
		end
		return ui.node("row", { gap = "md", align = "center" }, {
			ui.node("row", { gap = "xs", align = "center", min = { w = "16ch" } }, {
				ui.node("icon", { name = ROW_ICONS[field], tone = if active then "accent" else "muted" }),
				ui.text({ ui.span(labels[field], if active then "strong" else "muted") }),
			}),
			ui.button(current .. "  ▾", { key = field, size = "sm", actions = { click = "form-pick=" .. field } }),
		})
	end
	local children: { Node } = {
		ui.node("input", {
			key = "name",
			text = form.name,
			cursor = utf16_at(form.name, form.cursor),
			placeholder = "Card title",
			actions = { click = "form-name" },
		}),
		ui.node("rule", {}),
	}
	for _, field in form_fields(board) do
		if field ~= "name" then
			table.insert(children, row(field))
		end
	end
	if form.error then
		table.insert(children, ui.text({ ui.span(form.error, "error") }))
	end
	table.insert(
		children,
		ui.node("row", { key = "foot", gap = "md", justify = "between", align = "center" }, {
			ui.text({ ui.span("Tab next  ←→ change  space list", "dim") }),
			ui.node("row", { gap = "sm" }, {
				ui.button("Cancel", { variant = "quiet", keys = { "esc" }, actions = { click = "form-cancel" } }),
				ui.button("Create", { variant = "primary", keys = { "enter" }, busy = form.busy, actions = { click = "form-create" } }),
			}),
		})
	)
	return ui.node("overlay", { key = "form", modal = true, size = "md", head = "New card", meta = board.title, icon = "plus", foot = "layer.form.foot" }, children)
end

-- Settings -----------------------------------------------------------------------

-- The plugin's own settings page: Tern's Preferences › Plugins has only a
-- switch, Reload and Install for a plugin, so what can be changed lives here.
local function settings_view(state: State): Node
	local saved = tern.kv.get("token")
	local from = if type(saved) == "string" and saved ~= "" then "saved in Tern" elseif token() then "from the environment" else nil
	local board = state.board
	local children: { Node } = {
		ui.text({ ui.span("Integration token", "strong") }),
		ui.text({ ui.span(if from then "Set, " .. from .. "." else "Not set.", "muted") }),
		ui.text({ ui.span("To change it, paste the new token into this pane.", "dim") }),
	}
	if from == "saved in Tern" then
		table.insert(children, ui.row({ ui.button("Forget the saved token", { size = "sm", variant = "quiet", actions = { click = "forget-token" } }) }))
	end
	table.insert(children, ui.node("rule", {}))
	table.insert(children, ui.text({ ui.span("Board", "strong") }))
	if board then
		local where = board.project or state.workspace
		table.insert(children, ui.text({ ui.span(board.title .. (if where then " - " .. where else ""), "muted") }))
		local url = board.view_url or board.url
		if url then
			table.insert(children, ui.text({ ui.link("Open it in Notion", url) }))
		end
	else
		table.insert(children, ui.text({ ui.span("None yet.", "muted") }))
	end
	table.insert(
		children,
		ui.row({
			ui.button("Choose another board", {
				size = "sm",
				variant = "quiet",
				actions = { click = "change-board" },
			}),
		})
	)
	table.insert(children, ui.node("rule", {}))
	table.insert(children, ui.text({ ui.span("Options", "strong") }))
	table.insert(
		children,
		ui.row({
			ui.button("Hide empty columns: " .. (if state.hide_empty then "on" else "off"), {
				size = "sm",
				variant = if state.hide_empty then "primary" else "quiet",
				actions = { click = "hide-empty" },
			}),
			ui.button("Check for updates: " .. (if update.enabled() then "on" else "off"), {
				size = "sm",
				variant = if update.enabled() then "primary" else "quiet",
				actions = { click = "update-toggle" },
			}),
		})
	)
	table.insert(children, ui.node("rule", {}))
	table.insert(children, ui.text({ ui.span("Notion Kanban " .. state.installed .. "  ·  MIT  ·  ", "dim"), ui.link("source and releases", "https://github.com/emerycp/tern-notion-kanban") }))
	table.insert(
		children,
		ui.node("row", { key = "foot", justify = "end" }, {
			ui.button("Close", { variant = "quiet", keys = { "esc" }, actions = { click = "settings-close" } }),
		})
	)
	return ui.node("overlay", { key = "settings", modal = true, size = "md", head = "Notion Kanban settings", icon = "gear", foot = "layer.settings.foot" }, children)
end

-- Block ------------------------------------------------------------------------

tern.block.define("board", {
	font = "sans",


	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local state: State = {
			cx = cx,
			ref = nil,
			source = "project",
			switched = false,
			board = nil,
			loading = false,
			generation = 0,
			problem = nil,
			fetched = nil,
			col = 1,
			row = 0,
			first = 1,
			tops = {},
			panel = false,
			details = {},
			form = nil,
			lifted = nil,
			target = 1,
			users = {},
			again = false,
			only = nil,
			pool = {},
			learn = false,
			avatars = {},
			avatars_asked = {},
			hide_empty = false,
			all_columns = {},
			boards = nil,
			boards_loading = false,
			pick_at = 1,
			update = nil,
			updating = false,
			installed = update.current() or "?",
			workspace = nil,
			previous = nil,
			last_good = nil,
			settings = false,
			timer = nil,
		}
		if args[1] then
			state.ref = notion.parse_ref(args[1])
			state.source = "link"
			if not state.ref then
				state.problem = { kind = "noboard", text = "That is not a Notion database link." }
			end
		elseif type(saved) == "table" and type(saved.board) == "table" and type(saved.board.database) == "string" then
			state.ref = {
				database = saved.board.database,
				view = saved.board.view,
				group = if type(saved.board.group) == "string" then saved.board.group else nil,
			}
			state.source = "saved"
		else
			local ref, err = project_ref(cx.cwd)
			state.ref = ref
			if err then
				state.problem = { kind = "noboard", text = "The project's Notion setting is unusable.", detail = err }
			end
		end
		if type(saved) == "table" and type(saved.only) == "string" then
			state.only = saved.only
		end
		if type(saved) == "table" and saved.hide_empty == true then
			state.hide_empty = true
		end
		running[cx.pane] = state
		if not state.problem then
			refresh(state)
		end
		update.check(function(latest: string?)
			if latest and tern.kv.get("update_dismissed") ~= latest and alive(state) then
				state.update = latest
				state.cx:render()
			end
		end)
		poll(state)
		return state
	end,

	title = function(state: State): string?
		local board = state.board
		local name = if board then board.title else "Notion"
		local where = if board then (board.project or state.workspace) else nil
		if where then
			name = name .. " - " .. where
		end
		return NOTION_GLYPH .. " " .. name
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local board = state.board
		if board then
			local layer: { Node } = {}
			if state.form then
				table.insert(layer, form_view(state, board, state.form))
			end
			local main = board_view(state, board)
			local panel = if state.panel then panel_view(state, board) else nil
			if panel then
				main = ui.col({ ui.node("row", { key = "split", gap = "lg", align = "start" }, { main, panel }) })
			end
			local result: BlockView = {
				main = main,
				dock = dock_view(state, board),
				layer = if #layer > 0 then ui.col(layer) else nil,
			}
			if state.settings then
				table.insert(layer, settings_view(state))
				result.layer = ui.col(layer)
			end
			return result
		elseif state.problem then
			local result: BlockView = { main = problem_view(state, state.problem) }
			if state.settings then
				result.layer = ui.col({ settings_view(state) })
			end
			return result
		end
		return { main = ui.col({ ui.progress(nil, "Loading the Notion board…") }) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		local form = state.form
		if key.name == "paste" then
			local text = key.text or ""
			if form then
				if form.field == "name" and not form.busy then
					form_paste(form, text)
				end
				return true
			end
			if notion.is_token(text) then
				tern.kv.set("token", (string.gsub(text, "%s+", "")))
				cx:toast("info", "Notion token saved")
				state.problem = nil
				refresh(state)
				return true
			end
			local ref = notion.parse_ref(text)
			if ref then
				switch_board(state, ref, "paste")
				return true
			end
			cx:toast("error", "Not a Notion token or database link")
			return true
		end
		if not form then
			if state.settings then
				if key.name == "escape" or key.text == "," then
					state.settings = false
				end
				return true
			end
			if key.text == "," and not state.lifted and not (key.ctrl or key.alt or key.meta) then
				state.settings = true
				return true
			end
		end
		if form then
			form_key(state, key, cx)
			return true
		end
		if state.board == nil and key.name == "escape" and go_back(state) then
			return true
		end
		local listed = state.boards
		if state.board == nil and state.problem and state.problem.kind == "noboard" and listed then
			-- No board yet and a list of databases to pick from.
			if key.name == "up" then
				state.pick_at = math.max(1, state.pick_at - 1)
			elseif key.name == "down" then
				state.pick_at = math.min(math.max(1, #listed), state.pick_at + 1)
			elseif key.name == "enter" and #listed > 0 then
				switch_board(state, { database = listed[state.pick_at].database }, "paste")
			elseif key.text == "r" then
				state.boards = nil
				load_boards(state)
			else
				return false
			end
			return true
		end
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if state.lifted then
			if key.name == "escape" then
				state.lifted = nil
			elseif key.name == "left" or k == "h" then
				target_step(state, -1)
			elseif key.name == "right" or k == "l" then
				target_step(state, 1)
			elseif key.name == "enter" or key.name == "space" then
				drop_lifted(state)
			else
				return false
			end
			return true
		end
		if key.name == "escape" then
			if not state.panel then
				return false
			end
			state.panel = false
		elseif key.name == "left" or k == "h" then
			move_col(state, -1)
		elseif key.name == "right" or k == "l" then
			move_col(state, 1)
		elseif key.name == "up" or k == "k" then
			move_row(state, state.row - 1)
		elseif key.name == "down" or k == "j" then
			move_row(state, state.row + 1)
		elseif key.name == "page_up" then
			move_row(state, state.row - 5)
		elseif key.name == "page_down" then
			move_row(state, state.row + 5)
		elseif key.name == "home" or k == "g" then
			move_row(state, 1)
		elseif key.name == "end" or k == "G" then
			move_row(state, math.huge)
		elseif key.name == "space" then
			lift_selected(state)
		elseif key.name == "enter" then
			if not selected_card(state) then
				return false
			end
			state.panel = true
		elseif k == "o" then
			open_selected(state, cx)
		elseif k == "b" then
			open_board(state, cx)
		elseif k == "r" then
			refresh(state)
		elseif k == "H" or k == "<" then
			move_selected(state, -1)
		elseif k == "L" or k == ">" then
			move_selected(state, 1)
		elseif k == "n" then
			open_form(state, cx)
		elseif k == "v" then
			cycle_view(state, 1)
		elseif k == "V" then
			cycle_view(state, -1)
		elseif k == "m" then
			toggle_mine(state)
		elseif k == "e" then
			toggle_hide_empty(state)
		elseif k == "B" then
			choose_board(state)
		else
			return false
		end
		ensure_detail(state)
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		local form = state.form
		local board = state.board
		if ev.ev == "change" and type(ev.id) == "string" and type(ev.value) == "string" then
			if ends(ev.id, ".view") then
				switch_view(state, ev.value)
			elseif ends(ev.id, ".only") then
				pick_only(state, ev.value)
			elseif ends(ev.id, ".group") then
				switch_group(state, ev.value)
			end
			return
		end
		if ev.ev == "focus" and form and type(ev.id) == "string" then
			for _, field in { "name", "column", "sprint", "parent", "person" } do
				if ends(ev.id, "." .. field) then
					form.field = field
				end
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act = ev.act
		local value: string = if type(ev.value) == "string" then ev.value else ""
		if state.lifted and board and (act == "pick" or act == "drop") then
			-- A click while carrying drops: on a column, or on a card there.
			local c: number? = nil
			if act == "pick" then
				c = column_of(board, value)
			else
				for i, column in board.columns do
					if column.key == value then
						c = i
					end
				end
			end
			if c and board.columns[c].option then
				state.target = c
				drop_lifted(state)
			end
		elseif act == "lift" then
			if select_id(state, value) then
				lift_selected(state)
			end
		elseif act == "pick" then
			select_id(state, value)
			ensure_detail(state)
		elseif act == "panel" then
			if select_id(state, value) then
				state.panel = true
				ensure_detail(state)
			end
		elseif act == "browser" then
			if value ~= "" then
				select_id(state, value)
			end
			open_selected(state, cx)
		elseif act == "move" then
			local id, key = string.match(value, "^(.-)|(.*)$")
			if id and key and board then
				for to, column in board.columns do
					if column.key == key then
						move_card(state, id, to)
					end
				end
			end
		elseif act == "settings" then
			state.settings = true
		elseif act == "settings-close" then
			state.settings = false
		elseif act == "forget-token" then
			tern.kv.set("token", nil)
			state.settings = false
			state.board = nil
			state.boards = nil
			state.problem = { kind = "notoken", text = "Notion needs an integration token." }
		elseif act == "update-toggle" then
			update.set_enabled(not update.enabled())
			if not update.enabled() then
				state.update = nil
			end
		elseif act == "change-board" then
			choose_board(state)
		elseif act == "boards-refresh" then
			state.boards = nil
			load_boards(state)
		elseif act == "board-back" then
			go_back(state)
		elseif act == "board-pick" then
			local info = if state.boards then state.boards[tonumber(value) or 0] else nil
			if info then
				switch_board(state, { database = info.database }, "paste")
			end
		elseif act == "update" then
			run_update(state)
		elseif act == "update-later" then
			if state.update then
				tern.kv.set("update_dismissed", state.update)
			end
			state.update = nil
		elseif act == "hide-empty" then
			toggle_hide_empty(state)
		elseif act == "refresh" or act == "retry" then
			refresh(state)
		elseif act == "board" then
			open_board(state, cx)
		elseif act == "new" then
			open_form(state, cx)
		elseif act == "panel-close" then
			state.panel = false
		elseif act == "form-pick" then
			if form and board then
				open_picker(state, board, form, value, cx)
			end
		elseif act == "form-choose" then
			if form and board then
				choose_pick(state, board, form, tonumber(value) or 0, cx)
			end
		elseif act == "form-back" then
			if form then
				form.picking = nil
				form.query = ""
			end
		elseif act == "form-name" then
			if state.form then
				focus_field(state.form, "name", cx)
			end
		elseif act == "form-cancel" then
			state.form = nil
		elseif act == "form-create" then
			submit_form(state, cx)
		end
	end,

	save = function(state: State): any
		local ref = state.ref
		local out: { [string]: any } = {}
		if ref and (state.source ~= "project" or state.switched) then
			out.board = { database = ref.database, view = ref.view, group = ref.group }
		end
		out.only = state.only
		out.hide_empty = if state.hide_empty then true else nil
		return out
	end,
})
