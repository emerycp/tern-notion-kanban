--!strict
-- Notion-flavored Markdown (the `v2` page markdown) to the CommonMark + GFM
-- that `tern.ui.md` draws. Notion spells images, callouts, mentions, tables
-- and colors as HTML-like tags, which `md` would show as literal text.

local M = {}

local function unescape(s: string): string
	local out = string.gsub(s, "&quot;", '"')
	out = string.gsub(out, "&lt;", "<")
	out = string.gsub(out, "&gt;", ">")
	out = string.gsub(out, "&amp;", "&")
	return out
end

-- The value of attribute `name` in the text of a tag.
local function attr(tag: string, name: string): string?
	local value = string.match(tag, "%f[%w%-]" .. name .. '="([^"]*)"') or string.match(tag, "%f[%w%-]" .. name .. "='([^']*)'")
	if value then
		return unescape(value)
	end
	return nil
end

-- A URL safe as a Markdown link destination.
local function dest(url: string): string
	local out = string.gsub(url, "%s", "%%20")
	out = string.gsub(out, "%(", "%%28")
	out = string.gsub(out, "%)", "%%29")
	return out
end

local function label(text: string): string
	local out = string.gsub(text, "[%[%]]", "")
	return out
end

-- `**text**` that survives the spaces Notion keeps inside a styled run.
local function wrap(mark: string, text: string): string
	local lead, body, tail = string.match(text, "^(%s*)(.-)(%s*)$")
	if not body or body == "" then
		return text
	end
	return (lead or "") .. mark .. body .. mark .. (tail or "")
end

local MEDIA = { "pdf", "file", "audio", "video" }

-- Inline and single-line tags to Markdown.
local function inline(s: string): string
	-- Images, with or without a caption.
	s = string.gsub(s, "<image([^>]-)/>", function(a: string)
		local url = attr(a, "source")
		return if url then "![image](" .. dest(url) .. ")" else ""
	end)
	s = string.gsub(s, "<image([^>]-)>(.-)</image>", function(a: string, cap: string?)
		local caption = cap or ""
		local url = attr(a, "source")
		if not url then
			return caption
		end
		return "![" .. label(if caption ~= "" then caption else "image") .. "](" .. dest(url) .. ")"
	end)
	-- Other media: a link to the file.
	for _, tag in MEDIA do
		local function link(a: string, caption: string?): string
			local url = attr(a, "source")
			if not url then
				return caption or ""
			end
			local text = if caption and caption ~= "" then caption else tag
			return "[📎 " .. label(text) .. "](" .. dest(url) .. ")"
		end
		s = string.gsub(s, "<" .. tag .. "([^>]-)/>", function(a: string)
			return link(a, nil)
		end)
		s = string.gsub(s, "<" .. tag .. "([^>]-)>(.-)</" .. tag .. ">", link)
	end
	-- Pages, databases and folders.
	for _, def in { { "page", "📄" }, { "database", "🗄" }, { "folder", "📁" } } do
		s = string.gsub(s, "<" .. def[1] .. "([^>]-)>(.-)</" .. def[1] .. ">", function(a: string, title: string?)
			local tag, icon = def[1], def[2]
			local heading: string = title or ""
			local url = attr(a, "url")
			local text = icon .. " " .. label(if heading ~= "" then heading else tag)
			return if url then "[" .. text .. "](" .. dest(url) .. ")" else text
		end)
	end
	-- Mentions: a link when it points at the web, else its label.
	s = string.gsub(s, "<mention([^>]-)/>", function(a: string)
		local url = attr(a, "url")
		if url and string.sub(url, 1, 4) == "http" then
			return "[" .. label(url) .. "](" .. dest(url) .. ")"
		end
		return ""
	end)
	s = string.gsub(s, "<mention([^>]-)>(.-)</mention>", function(a: string, label_text: string?)
		local text = label_text or ""
		local url = attr(a, "url")
		if url and string.sub(url, 1, 4) == "http" then
			return "[" .. label(text) .. "](" .. dest(url) .. ")"
		end
		return if string.sub(url or "", 1, 7) == "user://" then "@" .. text else text
	end)
	s = string.gsub(s, "<link%-preview([^>]-)/>", function(a: string)
		local url = attr(a, "url")
		return if url then "[" .. label(url) .. "](" .. dest(url) .. ")" else ""
	end)
	s = string.gsub(s, "<date([^>]-)/>", function(a: string)
		local from, to = attr(a, "start"), attr(a, "end")
		if not from then
			return ""
		end
		return if to and to ~= from then from .. " → " .. to else from
	end)
	s = string.gsub(s, "<equation[^>]*>(.-)</equation>", "$%1$")
	-- Styled runs.
	s = string.gsub(s, "<b>(.-)</b>", function(t: string)
		return wrap("**", t)
	end)
	s = string.gsub(s, "<i>(.-)</i>", function(t: string)
		return wrap("*", t)
	end)
	s = string.gsub(s, "<s>(.-)</s>", function(t: string)
		return wrap("~~", t)
	end)
	s = string.gsub(s, "<br%s*/?>", "  \n")
	-- What is left (colors, underline, unknown tags): keep the words, drop the tag.
	s = string.gsub(s, "</?%a[%w%-]*>", "")
	s = string.gsub(s, "</?%a[%w%-]*%s[^>]*>", "")
	s = string.gsub(s, "<%a[%w%-]*/>", "")
	return s
end

local function cell(s: string): string
	local flat = string.gsub(s, "<br%s*/?>", " ")
	flat = inline(flat)
	flat = string.gsub(flat, "%s*\n%s*", " ")
	flat = string.gsub(flat, "|", "\\|")
	return (string.match(flat, "^%s*(.-)%s*$")) or flat
end

-- An HTML table to a pipe table.
local function table_md(html: string): { string }
	local rows: { { string } } = {}
	for row in string.gmatch(html, "<tr[^>]*>(.-)</tr>") do
		local cells: { string } = {}
		for body in string.gmatch(row, "<t[hd][^>]*>(.-)</t[hd]>") do
			table.insert(cells, cell(body))
		end
		if #cells > 0 then
			table.insert(rows, cells)
		end
	end
	local out: { string } = {}
	if #rows == 0 then
		return out
	end
	local width = 0
	for _, r in rows do
		width = math.max(width, #r)
	end
	local function line(r: { string }): string
		local padded: { string } = {}
		for i = 1, width do
			padded[i] = r[i] or ""
		end
		return "| " .. table.concat(padded, " | ") .. " |"
	end
	table.insert(out, line(rows[1]))
	local sep: { string } = {}
	for i = 1, width do
		sep[i] = "---"
	end
	table.insert(out, "| " .. table.concat(sep, " | ") .. " |")
	for i = 2, #rows do
		table.insert(out, line(rows[i]))
	end
	return out
end

-- Tags that wrap blocks. Quotes and callouts become `>` quotes; the rest only
-- group, so their opening and closing tags go.
local CONTAINERS = { "callout", "quote", "toggle", "columns", "column", "synced-block", "synced-block-reference", "tabs", "tab", "meeting-notes", "details" }

function M.from_notion(src: string): string
	local out: { string } = {}
	local quotes = 0 -- how many quote/callout containers are open
	local stack: { boolean } = {} -- per open container: does it quote?
	local fence: string? = nil
	local pending_table: { string }? = nil
	local icon_next: string? = nil -- a callout's icon, waiting for its first line of text

	local function emit(text: string)
		if icon_next and text ~= "" then
			text = icon_next .. " " .. text
			icon_next = nil
		end
		if quotes > 0 then
			local prefix = string.rep(">", quotes)
			text = if text == "" then prefix else prefix .. " " .. text
		end
		table.insert(out, text)
	end

	for raw in string.gmatch(src .. "\n", "(.-)\r?\n") do
		local line = raw
		if fence then
			emit(line)
			local close = string.match(line, "^%s*(`+)%s*$")
			if close and #close >= #(fence :: string) then
				fence = nil
			end
		elseif pending_table then
			table.insert(pending_table, line)
			if string.find(line, "</table>", 1, true) then
				for _, l in table_md(table.concat(pending_table, " ")) do
					emit(l)
				end
				pending_table = nil
			end
		else
			local open = string.match(line, "^%s*(```+)")
			if open then
				fence = open
				emit(line)
			elseif string.match(line, "^%s*<table[%s>]") then
				pending_table = { line }
				if string.find(line, "</table>", 1, true) then
					for _, l in table_md(line) do
						emit(l)
					end
					pending_table = nil
				end
			else
				local handled = false
				-- A closing container tag on a line of its own.
				local closing = string.match(line, "^%s*</([%a%-]+)>%s*$")
				if closing then
					for _, name in CONTAINERS do
						if name == closing and #stack > 0 then
							if table.remove(stack) then
								quotes -= 1
							end
							emit("")
							handled = true
						end
					end
				end
				-- An opening container tag, with the first line of its body after it.
				if not handled then
					local name, attrs, rest = string.match(line, "^%s*<([%a%-]+)([^>]*)>(.*)$")
					if name and attrs and rest then
						for _, container in CONTAINERS do
							if container == name then
								local quoting = name == "callout" or name == "quote"
								local body = rest
								local closes = false
								local inner = string.match(body, "^(.*)</" .. name .. ">%s*$")
								if inner then
									body = inner
									closes = true
								end
								if quoting then
									quotes += 1
								end
								if name == "callout" then
									local icon = attr(attrs, "icon")
									if body == "" then
										icon_next = icon
									else
										body = (if icon then icon .. " " else "") .. body
									end
								elseif name == "toggle" and body ~= "" then
									body = "**" .. inline(body) .. "**"
									emit(body)
									body = ""
								end
								if body ~= "" and name ~= "toggle" then
									emit(inline(body))
								end
								if closes then
									if quoting then
										quotes -= 1
									end
									emit("")
								else
									table.insert(stack, quoting)
								end
								handled = true
								break
							end
						end
					end
				end
				if not handled then
					-- Single-line block tags.
					local text = line
					local todo, checked = string.match(text, "^%s*<todo([^>]*)>(.-)</todo>%s*$")
					if todo then
						text = "- [" .. (if attr(todo, "checked") == "true" then "x" else " ") .. "] " .. (checked or "")
					end
					local heading, body = string.match(text, "^%s*<h([1-4])[^>]*>(.-)</h%1>%s*$")
					if heading then
						text = string.rep("#", tonumber(heading) :: number) .. " " .. (body or "")
					end
					local li = string.match(text, "^%s*<li[^>]*>(.-)</li>%s*$")
					if li then
						text = "- " .. li
					end
					local para = string.match(text, "^%s*<p[^>]*>(.-)</p>%s*$")
					if para then
						text = para
					end
					if string.match(text, "^%s*<p%s*/>%s*$") or string.match(text, "^%s*</?[ou]l[^>]*>%s*$") or string.match(text, "^%s*<table%-of%-contents[^>]*/>%s*$") then
						text = ""
					end
					emit(inline(text))
				end
			end
		end
	end
	return table.concat(out, "\n")
end

return M
