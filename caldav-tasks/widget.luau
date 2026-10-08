--!nonstrict
local PLUGIN = "tomassplatch/caldav-tasks"

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
	if noctalia.state.get("status") then
		barWidget.setText(tostring(openCount()))
		barWidget.setTooltip(noctalia.state.get("status") .. "\nClick to open the list")
	else
		barWidget.setText("…")
	end
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
