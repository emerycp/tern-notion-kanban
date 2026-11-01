--!strict
-- The window half: palette commands to open a board and to store the token.

local KIND = "notion.board"

local function open_board(cx: WindowCx, args: { string }?)
	if cx:new_block(KIND, args, "beside") == nil then
		cx:toast("error", "Notion is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open Notion board",
	icon = "kanban",
	keys = { "ctrl+alt+shift+m" },
	run = function(cx: WindowCx)
		open_board(cx, nil)
	end,
})

tern.command({
	id = "open-link",
	title = "Open Notion board from link…",
	icon = "link",
	run = function(cx: WindowCx)
		cx:prompt({ placeholder = "Notion database link", icon = "link", action = "open" }):next(function(text, _err, cx2)
			if text and cx2 and text ~= "" then
				open_board(cx2, { text })
			end
		end)
	end,
})

tern.command({
	id = "token",
	title = "Set Notion token…",
	icon = "key",
	run = function(cx: WindowCx)
		cx:prompt({ placeholder = "Integration token (ntn_…)", icon = "key", action = "save" }):next(function(text, _err, cx2)
			if text and cx2 and text ~= "" then
				tern.kv.set("token", (string.gsub(text, "%s+", "")))
				cx2:toast("info", "Notion token saved", "Open boards pick it up on their next refresh.")
			end
		end)
	end,
})
