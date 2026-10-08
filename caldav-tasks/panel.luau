--!nonstrict
local APP = "CalDAV Tasks"

local tasks = {}   -- all tasks from the service
local visible = {} -- open (not completed) tasks shown in the panel
local dav = nil
local MAX_ROWS = 200
local PAGE_SIZE = 9
local USE_SCROLL = true
local PANEL_HEIGHT = 560
local ROOT_HEIGHT = PANEL_HEIGHT - 16
local page = 1
local inputSeed = 0
local editingTask = nil -- the task whose editor is expanded
local tagQuery = ""     -- current text in the tag filter input
local tagSeed = 0       -- bumped to re-create (clear) the tag input
local dueSeed = 0       -- bumped to re-create the due-date input
local dueDraft = nil    -- {href, text}: due-date text typed but not yet submitted

local render -- forward declaration

local function requestRefresh()
	noctalia.state.set("refreshRequest", (noctalia.state.get("refreshRequest") or 0) + 1)
end

local function report(where, err)
	local msg = tostring(err)
	noctalia.notify(APP, "[" .. where .. "] " .. msg)
	noctalia.notify(APP, "»» " .. msg:sub(-90))
end

local function auth()
	return noctalia.getConfig("username") or "", noctalia.getConfig("password") or ""
end

-- ===== iCalendar helpers (plain string work, no host API) =====

local function eolOf(ics)
	return ics:find("\r\n", 1, true) and "\r\n" or "\n"
end

local function splitLines(ics)
	local text = ics:gsub("\r\n", "\n")
	local lines, pos = {}, 1
	while pos <= #text do
		local nl = text:find("\n", pos, true)
		if nl then
			lines[#lines + 1] = text:sub(pos, nl - 1)
			pos = nl + 1
		else
			lines[#lines + 1] = text:sub(pos)
			break
		end
	end
	return lines
end

local function isContinuation(line)
	local c = line:sub(1, 1)
	return c == " " or c == "\t"
end

local function propName(line)
	return (line:match("^([%w%-]+)[;:]") or ""):upper()
end

-- Escape a TEXT value (RFC 5545 3.3.11).
local function escapeText(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub(";", "\\;")
	s = s:gsub(",", "\\,")
	s = s:gsub("\r?\n", "\\n")
	return s
end

-- First top-level property line called `name` in the first VTODO, or nil.
local function readProp(ics, name)
	local inTodo, sub = false, 0
	for _, line in ipairs(splitLines(ics)) do
		if not isContinuation(line) then
			local upper = line:upper()
			if not inTodo then
				if upper == "BEGIN:VTODO" then inTodo = true end
			elseif upper:sub(1, 6) == "BEGIN:" then
				sub = sub + 1
			elseif upper:sub(1, 4) == "END:" then
				if sub == 0 then return nil end
				sub = sub - 1
			elseif sub == 0 and propName(line) == name then
				return line
			end
		end
	end
	return nil
end

-- Edit the top-level properties of the first VTODO: every property named in
-- `drop` (a set of upper-case names) is removed together with its folded
-- continuation lines, and the lines in `add` are inserted after BEGIN:VTODO.
-- Properties inside sub-components such as VALARM are never touched, and the
-- file's own line ending is kept.
local function editVtodo(ics, drop, add)
	local eol = eolOf(ics)
	local out = {}
	local inTodo, done, sub, skipping = false, false, 0, false
	for _, line in ipairs(splitLines(ics)) do
		local keep = true
		if isContinuation(line) then
			keep = not skipping
		else
			skipping = false
			local upper = line:upper()
			if not inTodo then
				if not done and upper == "BEGIN:VTODO" then
					inTodo = true
					out[#out + 1] = line
					for _, a in ipairs(add) do out[#out + 1] = a end
					keep = false
				end
			elseif upper:sub(1, 6) == "BEGIN:" then
				sub = sub + 1
			elseif upper:sub(1, 4) == "END:" then
				if sub == 0 then
					inTodo, done = false, true
				else
					sub = sub - 1
				end
			elseif sub == 0 and drop[propName(line)] then
				skipping = true
				keep = false
			end
		end
		if keep then out[#out + 1] = line end
	end
	return table.concat(out, eol) .. eol
end

-- Every edit also refreshes LAST-MODIFIED and DTSTAMP, as other clients do.
local function edit(ics, dropNames, addLines)
	local drop = { ["LAST-MODIFIED"] = true, ["DTSTAMP"] = true }
	for _, n in ipairs(dropNames) do drop[n] = true end
	local stamp = os.date("!%Y%m%dT%H%M%SZ")
	local add = { "LAST-MODIFIED:" .. stamp, "DTSTAMP:" .. stamp }
	for _, l in ipairs(addLines) do add[#add + 1] = l end
	return editVtodo(ics, drop, add)
end

local function setDone(ics)
	local stamp = os.date("!%Y%m%dT%H%M%SZ")
	return edit(ics, { "STATUS", "PERCENT-COMPLETION", "COMPLETED" }, {
		"STATUS:COMPLETED", "PERCENT-COMPLETION:100", "COMPLETED:" .. stamp,
	})
end

-- Replace the task's categories (all CATEGORIES lines) with `tags`.
local function setCategories(ics, tags)
	local add = {}
	if #tags > 0 then
		local escaped = {}
		for i, tag in ipairs(tags) do escaped[i] = escapeText(tag) end
		add[1] = "CATEGORIES:" .. table.concat(escaped, ",")
	end
	return edit(ics, { "CATEGORIES" }, add)
end

-- DUE must have the same value type as DTSTART (DATE vs DATE-TIME), so the new
-- line follows the task's DTSTART when it has one.
local function dueLineFor(ics, ymd)
	local ds = readProp(ics, "DTSTART")
	if not ds then return "DUE;VALUE=DATE:" .. ymd end
	local value = ds:match("^[^:]*:(.*)$") or ""
	if not value:find("T", 1, true) then return "DUE;VALUE=DATE:" .. ymd end
	if value:sub(-1) == "Z" then return "DUE:" .. ymd .. "T000000Z" end
	local tzid = ds:match(";TZID=([^:;]+)")
	if tzid then return "DUE;TZID=" .. tzid .. ":" .. ymd .. "T000000" end
	return "DUE:" .. ymd .. "T000000"
end

-- Set (or clear) the DUE line. dateStr is "YYYY-MM-DD" or nil.
local function setDue(ics, dateStr)
	local add = {}
	if dateStr then
		add[1] = dueLineFor(ics, (dateStr:gsub("-", "")))
	end
	-- a task cannot have both DUE and DURATION
	return edit(ics, { "DUE", "DURATION" }, add)
end

-- ===== end of iCalendar helpers =====

local function rebuildVisible()
	visible = {}
	for _, t in ipairs(tasks) do
		if not t.done then
			visible[#visible + 1] = t
		end
	end
end

local function taskHasTag(t, tag)
	for _, x in ipairs(t.tags or {}) do
		if x == tag then return true end
	end
	return false
end

-- Tags used anywhere in the calendar (sorted, deduplicated).
local function collectAllTags()
	local seen = {}
	local out = {}
	for _, t in ipairs(tasks) do
		for _, tag in ipairs(t.tags or {}) do
			if not seen[tag] then
				seen[tag] = true
				out[#out + 1] = tag
			end
		end
	end
	table.sort(out)
	return out
end

-- Change one task on the server: GET the live VTODO, apply `transform`, PUT it
-- back. The PUT carries If-Match with the ETag from the last sync, so a change
-- made elsewhere in between is rejected (HTTP 412) instead of overwritten.
-- The service does not know the new ETag after our own write, so it is
-- dropped until the next sync supplies it.
local function updateTask(t, label, transform)
	local u, p = auth()
	noctalia.http({
		url = t.href,
		method = "GET",
		basic_username = u,
		basic_password = p,
	}, function(resp)
		local ok, err = pcall(function()
			local status = resp and resp.status
			if status == 404 then
				noctalia.notify(APP, label .. ": this task no longer exists on the server")
				requestRefresh()
				return
			end
			if not (resp and resp.ok and status == 200) then
				noctalia.notify(APP, label .. ": could not read the task (HTTP " .. tostring(status) .. ")")
				requestRefresh()
				return
			end
			local ics = resp.body or ""
			if not ics:find("BEGIN:VTODO", 1, true) then
				noctalia.notify(APP, label .. ": the server did not return a task")
				requestRefresh()
				return
			end
			local headers = { "Content-Type: text/calendar; charset=utf-8" }
			if t.etag and not t.etag:find("^W/") then
				headers[#headers + 1] = "If-Match: " .. t.etag
			end
			noctalia.http({
				url = t.href,
				method = "PUT",
				body = transform(ics),
				headers = headers,
				basic_username = u,
				basic_password = p,
			}, function(putResp)
				local s = putResp and putResp.status
				if putResp and putResp.ok and (s == 200 or s == 201 or s == 204) then
					t.etag = nil
				elseif s == 412 then
					noctalia.notify(APP, label .. ": the task was changed elsewhere — refreshed, please try again")
				else
					noctalia.notify(APP, label .. " failed: HTTP " .. tostring(s))
				end
				requestRefresh()
			end)
		end)
		if not ok then
			report(label, err)
			requestRefresh()
		end
	end)
end

-- Optimistically update + persist a task's tag list.
local function saveTaskTags(t, newTags)
	t.tags = newTags
	render()
	updateTask(t, "Tag save", function(ics) return setCategories(ics, newTags) end)
end

-- Optimistically update + persist a task's due date. dateStr "YYYY-MM-DD" or nil.
local function saveTaskDue(t, dateStr)
	t.due = dateStr and dateStr:gsub("-", "") or nil
	render()
	updateTask(t, "Due date save", function(ics) return setDue(ics, dateStr) end)
end

local function addTagTo(t, tag)
	if taskHasTag(t, tag) then return end
	local new = {}
	for _, x in ipairs(t.tags or {}) do new[#new + 1] = x end
	new[#new + 1] = tag
	saveTaskTags(t, new)
end

local function removeTagFrom(t, tag)
	local new = {}
	for _, x in ipairs(t.tags or {}) do
		if x ~= tag then new[#new + 1] = x end
	end
	if #new == #(t.tags or {}) then return end
	saveTaskTags(t, new)
end

-- Complete a task.
local function completeTask(t)
	if not t or t.done then return end

	t.done = true
	editingTask = nil
	tagQuery = ""
	rebuildVisible()
	render()

	updateTask(t, "Complete", setDone)
end

-- Add a task: PUT a new VTODO to a UID-derived URL.
local function addTask(value)
	local text = ((value or ""):match("^%s*(.-)%s*$"))
	if text == "" then return end
	local calUrl = dav and dav.calUrl
	if not calUrl then
		noctalia.notify(APP, "Calendar URL not known yet — try again in a moment")
		return
	end
	local u, p = auth()
	local stamp = os.date("!%Y%m%dT%H%M%SZ")
	local uid = ("%s-%d-%d"):format(stamp, os.time(), math.random(1000000))
	local body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//CalDAV Tasks Sync (Noctalia)//EN\r\n"
		.. "BEGIN:VTODO\r\nUID:" .. uid .. "\r\nCREATED:" .. stamp .. "\r\n"
		.. "LAST-MODIFIED:" .. stamp .. "\r\nDTSTAMP:" .. stamp .. "\r\n"
		.. "SUMMARY:" .. escapeText(text) .. "\r\nSTATUS:NEEDS-ACTION\r\n"
		.. "END:VTODO\r\nEND:VCALENDAR\r\n"
	local href = calUrl .. uid .. ".ics"
	noctalia.http({
		url = href,
		method = "PUT",
		body = body,
		-- never overwrite an existing resource
		headers = { "Content-Type: text/calendar; charset=utf-8", "If-None-Match: *" },
		basic_username = u,
		basic_password = p,
	}, function(resp)
		if not (resp and resp.ok and (resp.status == 200 or resp.status == 201 or resp.status == 204)) then
			noctalia.notify(APP, "Add failed: HTTP " .. tostring(resp and resp.status))
		end
		requestRefresh()
	end)
end

-- Tag capsule; optionally clickable.
local function tagChip(tag, onClick)
	local props = {
		fill = "on_surface/0.08",
		radius = 999,
		paddingH = 8,
		paddingV = 3,
		align = "center",
	}
	if onClick then props.onClick = onClick end
	return ui.row(props, {
		ui.label({ text = tostring(tag), fontSize = 10, color = "on_surface/0.7" }),
	})
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function dueInfo(raw)
	if type(raw) ~= "string" then return nil, false end
	local y, m, d = raw:match("^(%d%d%d%d)(%d%d)(%d%d)")
	local yi, mi, di = tonumber(y), tonumber(m), tonumber(d)
	if not (yi and mi and di and mi >= 1 and mi <= 12 and di >= 1 and di <= 31) then
		return nil, false
	end
	local now = os.date("*t")
	local todayNum = now.year * 10000 + now.month * 100 + now.day
	local num = yi * 10000 + mi * 100 + di
	local text = tostring(di) .. " " .. (MONTHS[mi] or "?")
	if yi ~= now.year then
		text = text .. " '" .. tostring(yi):sub(3)
	end
	return text, (num < todayNum)
end

-- Validate and save a due-date text ("" clears the date).
-- Returns false (after telling the user) if the format is wrong.
local function commitDue(t, text)
	local s = ((text or ""):match("^%s*(.-)%s*$"))
	if s == "" then
		saveTaskDue(t, nil)
		return true
	end
	local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if y and tonumber(m) >= 1 and tonumber(m) <= 12 and tonumber(d) >= 1 and tonumber(d) <= 31 then
		saveTaskDue(t, s)
		return true
	end
	noctalia.notify(APP, "Format: YYYY-MM-DD (e.g. 2026-10-31)")
	return false
end

-- The tag editor: filter-and-add input + suggestion chips + removable tags + due date.
local function tagEditor(t)
	local children = {}

	-- Current tags: click to remove.
	local current = t.tags or {}
	if #current > 0 then
		local chips = {}
		for _, tag in ipairs(current) do
			chips[#chips + 1] = tagChip("× " .. tostring(tag), function() removeTagFrom(t, tag) end)
		end
		children[#children + 1] = ui.row({ gap = 4, align = "center" }, chips)
	end

	-- Filter input with a tag glyph (same layout as the due-date row).
	-- Stable key + no `value` prop => uncontrolled buffer
	-- survives the per-keystroke re-render.
	children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "tag", size = 14, color = "on_surface/0.6" }),
		ui.input({
			key = "tagquery-" .. tagSeed,
			placeholder = "Filter or new tag… (Enter adds)", controlSize = "sm",
			flexGrow = 1,
			onChange = function(text)
				tagQuery = tostring(text or "")
				render()
			end,
			onSubmit = function(val)
				local tag = (((val ~= nil and val) or tagQuery or ""):match("^%s*(.-)%s*$"))
				tag = (tag:gsub(",", ""))
				if #tag > 0 then
					addTagTo(t, tag)
				end
				tagQuery = ""
				tagSeed = tagSeed + 1
				render()
			end,
		}),
	})

	-- Suggestion chips: existing tags matching the query, not yet on this task.
	local q = (tagQuery or ""):lower()
	local matches = {}
	for _, tag in ipairs(collectAllTags()) do
		if not taskHasTag(t, tag) then
			if q == "" or tostring(tag):lower():find(q, 1, true) then
				matches[#matches + 1] = tag
			end
		end
	end
	local chips = {}
	for i = 1, math.min(#matches, 8) do
		chips[#chips + 1] = tagChip(matches[i], function() addTagTo(t, matches[i]) end)
	end
	if #chips > 0 then
		children[#children + 1] = ui.row({ gap = 4, align = "center" }, chips)
	elseif q ~= "" then
		children[#children + 1] = ui.label({ text = "↵ creates \"" .. tagQuery .. "\"", color = "on_surface/0.6" })
	end

	-- Due date editor: prefilled, Enter saves; empty Enter clears.
	-- Text typed but not submitted is saved when "Done" is clicked.
	local dy, dm, dd
	if t.due then
		dy, dm, dd = tostring(t.due):match("^(%d%d%d%d)(%d%d)(%d%d)")
	end
	local prefilled = dy and (dy .. "-" .. dm .. "-" .. dd) or ""
	children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "calendar", size = 14, color = "on_surface/0.6" }),
		ui.input({
			key = "due-" .. tostring(t.href) .. "-" .. dueSeed, value = prefilled,
			placeholder = "YYYY-MM-DD (empty clears)", controlSize = "sm",
			flexGrow = 1,
			-- remember the text only; no render() here, so typing is not disturbed
			onChange = function(text)
				dueDraft = { href = t.href, text = tostring(text or "") }
			end,
			onSubmit = function(val)
				commitDue(t, val)
				dueDraft = nil
				dueSeed = dueSeed + 1
				render()
			end,
		}),
	})

	children[#children + 1] = ui.button({
		text = "Done", variant = "ghost",
		onClick = function()
			local draft = dueDraft
			dueDraft = nil
			if draft and draft.href == t.href and draft.text ~= prefilled then
				if not commitDue(t, draft.text) then
					dueDraft = draft -- invalid format: keep the editor open to fix it
					return
				end
				dueSeed = dueSeed + 1
			end
			editingTask = nil
			tagQuery = ""
			render()
		end,
	})

	return ui.column({ gap = 6, padding = 8, paddingLeft = 40 }, children)
end

-- One task row: circle completes, pencil toggles the editor, due date next to tags.
local function taskRow(task)
	local tags = task.tags or {}
	local children = {
		ui.button({ glyph = "circle", variant = "ghost", onClick = function() completeTask(task) end }),
		ui.label({ text = tostring(task.summary), maxLines = 1, flexGrow = 1 }),
	}
	for i = 1, math.min(#tags, 2) do
		children[#children + 1] = tagChip(tags[i])
	end
	local dueText, overdue = dueInfo(task.due)
	if dueText then
		children[#children + 1] = ui.label({
			text = overdue and ("! " .. dueText) or dueText,
			fontSize = 10,
			color = overdue and "primary" or "on_surface/0.6",
		})
	end
	local active = (editingTask == task)
	children[#children + 1] = ui.button({
		glyph = "pencil", variant = "ghost",
		onClick = function()
			if active then
				editingTask = nil
			else
				editingTask = task
			end
			tagQuery = ""
			dueDraft = nil
			render()
		end,
	})
	return ui.row({
		key = "task-" .. tostring(task.href or task.summary),
		gap = 8,
		align = "center",
		tooltip = (#tags > 0) and table.concat(tags, ", ") or nil,
	}, children)
end

function onRefreshClicked() requestRefresh() end
function onPrevPage() page = page - 1; render() end
function onNextPage() page = page + 1; render() end

function onAddSubmit(value)
	addTask(value)
	inputSeed = inputSeed + 1
	render()
end

render = function()
	local shown = math.min(#visible, MAX_ROWS)
	local pages = math.max(1, math.ceil(shown / PAGE_SIZE))
	if page > pages then page = pages end
	if page < 1 then page = 1 end

	local header = ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = "Tasks", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
		ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
	})

	local input = ui.input({
		key = "newtask-" .. inputSeed, value = "", focus = true,
		placeholder = "New task… (Enter to add)", onSubmit = "onAddSubmit",
	})

	local rows = {}
	if #visible == 0 then
		rows[1] = ui.column({ align = "center", gap = 6, paddingV = 24 }, {
			ui.glyph({ name = "check", size = 32, color = "primary" }),
			ui.label({ text = "All done!", color = "on_surface/0.6" }),
		})
	else
		local first, last = 1, shown
		if not USE_SCROLL then
			first = (page - 1) * PAGE_SIZE + 1
			last = math.min(first + PAGE_SIZE - 1, shown)
		end
		for i = first, last do
			local t = visible[i]
			rows[#rows + 1] = taskRow(t)
			if editingTask == t then
				rows[#rows + 1] = tagEditor(t)
			end
		end
		if #visible > MAX_ROWS then
			rows[#rows + 1] = ui.label({
				text = "Showing the first " .. MAX_ROWS .. " of " .. #visible .. " open",
				color = "on_surface/0.6",
			})
		end
	end

	if USE_SCROLL then
		panel.render(ui.column({ gap = 8, padding = 12, height = ROOT_HEIGHT }, {
			header,
			input,
			ui.separator({}),
			ui.scroll({ gap = 4, flexGrow = 1 }, rows),
		}))
	else
		local children = { header, input, ui.separator({}) }
		for _, row in ipairs(rows) do children[#children + 1] = row end
		panel.render(ui.column({ gap = 8, padding = 12, height = ROOT_HEIGHT }, children))
	end
end

function onOpen(_context)
	local ok, err = pcall(function()
		render()
	end)
	if not ok then report("onOpen-render", err) end
	requestRefresh()
end

noctalia.state.watch("tasks", function(value)
	local ok, err = pcall(function()
		tasks = value or {}
		for _, t in ipairs(tasks) do
			if t.due ~= nil then t.due = tostring(t.due) end
		end
		-- drop the editor if its task vanished
		if editingTask then
			local href = editingTask.href
			local found
			for _, t in ipairs(tasks) do
				if t.href == href then found = t break end
			end
			editingTask = found
			if not found then tagQuery = "" end
		end
		rebuildVisible()
		render()
	end)
	if not ok then report("watch-tasks", err) end
end)

noctalia.state.watch("dav", function(value)
	dav = value
end)
