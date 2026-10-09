--!nonstrict
local PLUGIN = "tomassplatch/caldav-tasks" -- must match `id` in plugin.toml

local function openCount()
	local n = 0
	local tasks = noctalia.state.get("tasks")
	for _, t in ipairs(tasks or {}) do
		if not t.done then n = n + 1 end
	end
	return n
end

local function render()
	barWidget.setGlyph("check")
	local status = noctalia.state.get("status")
	if not status then
		barWidget.setText("…")
		return
	end
	-- "statusKind" is published by service.luau: "ok" | "syncing" | "error"
	local failing = noctalia.state.get("statusKind") == "error"
	barWidget.setText(tostring(openCount()) .. (failing and " !" or ""))
	barWidget.setTooltip(tostring(status) .. "\nClick to open the list")
end

function update()
	noctalia.setUpdateInterval(600000)
	render()
end

-- status changes on every sync (unique timestamp), so this fires reliably
-- even when the task list itself is unchanged between syncs.
noctalia.state.watch("status", render)
noctalia.state.watch("tasks", render)

function onClick()
	noctalia.runAsync({ "noctalia", "msg", "panel-toggle", PLUGIN .. ":panel" })
end
