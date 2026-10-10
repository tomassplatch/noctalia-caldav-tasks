--!nonstrict
local APP = "CalDAV Tasks"

local tasks = {}   -- all tasks from the service
local visible = {} -- open (not completed) tasks shown in the panel
local dav = nil
local MAX_ROWS = 200
local PANEL_HEIGHT = 560 -- keep in sync with the [[panel]] height in plugin.toml
local ROOT_HEIGHT = PANEL_HEIGHT - 16
local CHIPS_PER_ROW = 5 -- quick-date chips per line; lower it if they are clipped
local inputSeed = 0
local editingTask = nil -- the task whose editor is expanded
local tagQuery = ""     -- current text in the tag filter input
local tagSeed = 0       -- bumped to re-create (clear) the tag input
local dueSeed = 0       -- bumped to re-create the due-date input
local dueDraft = nil    -- {href, text}: due-date text typed but not yet submitted
local titleDraft = nil  -- {href, text}: title text typed but not yet submitted
local RECENT_SECONDS = 30 -- how long a completed task stays visible
local recent = {}         -- href -> { task = <task>, at = <os.time() when completed> }
local doneRows = {}       -- recently completed tasks, oldest first


local render -- forward declaration

local function requestRefresh()
	noctalia.state.set("refreshRequest", (noctalia.state.get("refreshRequest") or 0) + 1)
end

local function report(where, err)
	local msg = "[" .. where .. "] " .. tostring(err)
	noctalia.log(msg)
	noctalia.notifyError(APP, msg)
end

local function auth()
	return noctalia.getConfig("username") or "", noctalia.getConfig("password") or ""
end

-- Credentials are only ever sent to the configured server (fetch_tasks.py
-- enforces the same rule for its own requests).
local function originOf(url)
	local scheme, host = tostring(url or ""):match("^(%a[%w+.-]*)://([^/]+)")
	if not scheme then return nil end
	return scheme:lower() .. "://" .. host:lower()
end

local function isConfiguredServer(url)
	local want = originOf(noctalia.getConfig("server"))
	return want ~= nil and originOf(url) == want
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

-- Undo of setDone: back to an open task.
local function setReopen(ics)
	return edit(ics, { "STATUS", "PERCENT-COMPLETION", "COMPLETED" }, { "STATUS:NEEDS-ACTION" })
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

-- Replace the task's title.
local function setSummary(ics, text)
	return edit(ics, { "SUMMARY" }, { "SUMMARY:" .. escapeText(text) })
end

-- ===== end of iCalendar helpers =====

-- Tick every second only while completed tasks are waiting to expire.
local function updateTicks()
	pcall(panel.setWantsSecondTicks, next(recent) ~= nil)
end

-- Forget completed tasks whose time is up. Returns true if any was removed.
local function pruneRecent()
	local now = os.time()
	local removed = false
	for href, info in pairs(recent) do
		if now - info.at >= RECENT_SECONDS then
			recent[href] = nil
			removed = true
		end
	end
	return removed
end

local function rebuildVisible()
	pruneRecent()
	visible = {}
	doneRows = {}
	local byHref = {}
	for _, t in ipairs(tasks) do
		byHref[t.href] = t
		if not t.done and not recent[t.href] then
			visible[#visible + 1] = t
		end
	end
	local entries = {}
	for href, info in pairs(recent) do
		entries[#entries + 1] = { task = byHref[href] or info.task, at = info.at }
	end
	table.sort(entries, function(a, b)
		if a.at ~= b.at then return a.at < b.at end
		return tostring(a.task.href) < tostring(b.task.href)
	end)
	for _, e in ipairs(entries) do
		e.task.done = true
		doneRows[#doneRows + 1] = e.task
	end
	updateTicks()
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
local function updateTask(t, label, transform, onFail)
	if t.creating then
		noctalia.notify(APP, label .. ": the task is still being created — try again in a moment")
		requestRefresh()
		return
	end
	if not isConfiguredServer(t.href) then
		noctalia.notify(APP, label .. ": refusing to send credentials to a different server")
		if onFail then onFail() end
		return
	end
	local u, p = auth()
	local function failed()
		if onFail then onFail() end
	end
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
				failed()
				requestRefresh()
				return
			end
			if not (resp and resp.ok and status == 200) then
				noctalia.notify(APP, label .. ": could not read the task (HTTP " .. tostring(status) .. ")")
				failed()
				requestRefresh()
				return
			end
			local ics = resp.body or ""
			if not ics:find("BEGIN:VTODO", 1, true) then
				noctalia.notify(APP, label .. ": the server did not return a task")
				failed()
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
					failed()
				else
					noctalia.notify(APP, label .. " failed: HTTP " .. tostring(s))
					failed()
				end
				requestRefresh()
			end)
		end)
		if not ok then
			report(label, err)
			failed()
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

-- Optimistically update + persist a task's title.
local function saveTaskTitle(t, text)
	t.summary = text
	render()
	updateTask(t, "Rename", function(ics) return setSummary(ics, text) end)
end

-- Title and due date in a single write (two writes would race on the same ETag).
local function saveTaskTitleAndDue(t, text, dateStr)
	t.summary = text
	t.due = dateStr and dateStr:gsub("-", "") or nil
	render()
	updateTask(t, "Save", function(ics) return setDue(setSummary(ics, text), dateStr) end)
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

-- Complete a task: it moves to the end of the list, dimmed, until its time is up.
local function completeTask(t)
	if not t or t.done then return end

	t.done = true
	recent[t.href] = { task = t, at = os.time() }
	editingTask = nil
	tagQuery = ""
	rebuildVisible()
	render()

	updateTask(t, "Complete", setDone, function()
		-- the write failed: it is not completed after all
		recent[t.href] = nil
		t.done = false
		rebuildVisible()
		render()
	end)
end

-- Reopen a task that was completed a moment ago.
local function undoComplete(t)
	if not recent[t.href] then return end
	recent[t.href] = nil
	t.done = false
	rebuildVisible()
	render()
	updateTask(t, "Undo", setReopen)
end

-- [dates:begin]
-- Dates. A day number (days since 1970-01-01) turns date arithmetic into plain
-- integer maths. Only todayNum() reads the clock, so everything else can be
-- tested with a fixed "today".

local function monthLength(y, m)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then return 29 end
	return days[m]
end

-- A real calendar date (the old range checks accepted 2026-02-31).
local function isRealDate(y, m, d)
	if m < 1 or m > 12 or d < 1 then return false end
	return d <= monthLength(y, m)
end

local function daysFromCivil(y, m, d)
	if m <= 2 then y = y - 1 end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m > 2) and (m - 3) or (m + 9)
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z)
	z = z + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
		- math.floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = (mp < 10) and (mp + 3) or (mp - 9)
	if m <= 2 then y = y + 1 end
	return y, m, d
end

local function ymdOf(n)
	local y, m, d = civilFromDays(n)
	return ("%04d-%02d-%02d"):format(y, m, d)
end

local function todayNum()
	local t = os.date("*t")
	return daysFromCivil(t.year, t.month, t.day)
end

-- Monday = 0 … Sunday = 6
local function weekdayOf(n) return (n + 3) % 7 end

-- The Friday that ends the current working week. On Saturday and Sunday the
-- current week is the one that starts on Monday.
local function endOfWeek(n)
	local wd = weekdayOf(n)
	return n + (wd <= 4 and (4 - wd) or (11 - wd))
end

local function endOfMonth(n)
	local y, m = civilFromDays(n)
	return daysFromCivil(y, m, monthLength(y, m))
end

-- Quick-pick dates for the editor. A chip whose date is the same as an earlier
-- one is left out (on a Thursday, "This week" would just repeat "Tomorrow").
local function dueChips(today)
	local candidates = {
		{ "Today", today },
		{ "Tomorrow", today + 1 },
		{ "This week", endOfWeek(today) },
		{ "Next week", endOfWeek(today) + 7 },
		{ "Month", endOfMonth(today) },
	}
	local out, used = {}, {}
	for _, c in ipairs(candidates) do
		if not used[c[2]] then
			used[c[2]] = true
			out[#out + 1] = { label = c[1], ymd = ymdOf(c[2]) }
		end
	end
	return out
end

local WEEKDAYS = {
	mon = 0, monday = 0, tue = 1, tues = 1, tuesday = 1, wed = 2, weds = 2, wednesday = 2,
	thu = 3, thur = 3, thurs = 3, thursday = 3, fri = 4, friday = 4,
	sat = 5, saturday = 5, sun = 6, sunday = 6,
}

-- Read a due-date text. Returns ok, "YYYY-MM-DD" (nil date with ok = clear the date).
-- Accepted: 2026-10-31 · today, tomorrow · mon … sun (the next one) · +3, 3d, 2w ·
-- 31.10, 31/10 (day first, the next time that date comes round) · 31.10.2026, 31.10.26
local function parseDueText(text, today)
	local s = (text or ""):lower():match("^%s*(.-)%s*$")
	if s == "" then return true, nil end

	local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
	if y then
		if isRealDate(tonumber(y), tonumber(m), tonumber(d)) then
			return true, ymdOf(daysFromCivil(tonumber(y), tonumber(m), tonumber(d)))
		end
		return false, nil
	end

	if s == "today" then return true, ymdOf(today) end
	if s == "tomorrow" or s == "tom" then return true, ymdOf(today + 1) end

	local wd = WEEKDAYS[s]
	if wd then
		local delta = (wd - weekdayOf(today)) % 7
		if delta == 0 then delta = 7 end
		return true, ymdOf(today + delta)
	end

	local n, unit = s:match("^%+(%d+)([dw]?)$")
	if not n then n, unit = s:match("^(%d+)([dw])$") end
	if n then
		n = tonumber(n) * (unit == "w" and 7 or 1)
		if n > 3650 then return false, nil end
		return true, ymdOf(today + n)
	end

	s = s:gsub("[./%-]+$", "") -- "10.11." -> "10.11"
	local a, b, c = s:match("^(%d+)[./%-](%d+)[./%-](%d+)$")
	if a then
		local yy, mm, dd
		if #a == 4 then
			yy, mm, dd = a, b, c
		else
			dd, mm, yy = a, b, c
			if #yy == 2 then yy = "20" .. yy end
		end
		if #yy == 4 and #mm <= 2 and #dd <= 2
			and isRealDate(tonumber(yy), tonumber(mm), tonumber(dd)) then
			return true, ymdOf(daysFromCivil(tonumber(yy), tonumber(mm), tonumber(dd)))
		end
		return false, nil
	end

	a, b = s:match("^(%d+)[./%-](%d+)$")
	if a and #a <= 2 and #b <= 2 then
		local dd, mm = tonumber(a), tonumber(b)
		local thisYear = civilFromDays(today)
		for yy = thisYear, thisYear + 8 do -- 29.2 may be a few years away
			if isRealDate(yy, mm, dd) then
				local n2 = daysFromCivil(yy, mm, dd)
				if n2 >= today then return true, ymdOf(n2) end
			end
		end
	end
	return false, nil
end

-- "Pay invoice !fri" -> "Pay invoice", "2026-10-16". Only a last word that starts
-- with "!" and reads as a date is taken; anything else stays part of the title.
local function splitDueSuffix(text, today)
	local title, token = text:match("^(.-)%s+!(%S+)$")
	if title and title ~= "" then
		local ok, ymd = parseDueText(token, today)
		if ok and ymd then return title, ymd end
	end
	return text, nil
end
-- [dates:end]

-- Add a task: show it at once, PUT a new VTODO to a UID-derived URL, and let
-- the next sync replace the temporary entry with the server's copy.
local function addTask(value)
	local text = ((value or ""):match("^%s*(.-)%s*$"))
	if text == "" then return end
	local dueYmd
	text, dueYmd = splitDueSuffix(text, todayNum())
	local dueDigits = dueYmd and (dueYmd:gsub("-", "")) or nil
	local calUrl = dav and dav.calUrl
	if not calUrl then
		noctalia.notify(APP, "Calendar URL not known yet — try again in a moment")
		return
	end
	if not isConfiguredServer(calUrl) then
		noctalia.notify(APP, "Calendar URL is on a different server — not sending credentials")
		return
	end
	local u, p = auth()
	local stamp = os.date("!%Y%m%dT%H%M%SZ")
	local uid = ("%s-%d-%d"):format(stamp, os.time(), math.random(1000000))
	local body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//CalDAV Tasks Sync (Noctalia)//EN\r\n"
		.. "BEGIN:VTODO\r\nUID:" .. uid .. "\r\nCREATED:" .. stamp .. "\r\n"
		.. "LAST-MODIFIED:" .. stamp .. "\r\nDTSTAMP:" .. stamp .. "\r\n"
		.. "SUMMARY:" .. escapeText(text) .. "\r\nSTATUS:NEEDS-ACTION\r\n"
		.. (dueDigits and ("DUE;VALUE=DATE:" .. dueDigits .. "\r\n") or "")
		.. "END:VTODO\r\nEND:VCALENDAR\r\n"
	local href = calUrl .. uid .. ".ics"

	-- Temporary entry, shown at the top. `creating` blocks edits until the PUT
	-- has finished. A new list is built so the shared one is not modified.
	local newTask = {
		href = href, etag = nil, summary = text,
		done = false, tags = {}, due = dueDigits, creating = true,
	}
	local updated = { newTask }
	for _, x in ipairs(tasks) do updated[#updated + 1] = x end
	tasks = updated
	rebuildVisible()
	render()

	noctalia.http({
		url = href,
		method = "PUT",
		body = body,
		-- never overwrite an existing resource
		headers = { "Content-Type: text/calendar; charset=utf-8", "If-None-Match: *" },
		basic_username = u,
		basic_password = p,
	}, function(resp)
		newTask.creating = false
		if not (resp and resp.ok and (resp.status == 200 or resp.status == 201 or resp.status == 204)) then
			noctalia.notify(APP, "Add failed: HTTP " .. tostring(resp and resp.status))
			-- take the temporary entry back out
			local kept = {}
			for _, x in ipairs(tasks) do
				if x ~= newTask then kept[#kept + 1] = x end
			end
			tasks = kept
			rebuildVisible()
			render()
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

-- Read a due-date text; tells the user and returns false if it is not a date.
local function parseDue(text)
	local ok, ymd = parseDueText(text, todayNum())
	if not ok then
		noctalia.notify(APP, "Not a date. Try 2026-10-31, 31.10, fri, +3 or 2w")
	end
	return ok, ymd
end

-- Validate and save a due-date text ("" clears the date).
local function commitDue(t, text)
	local ok, dateStr = parseDue(text)
	if not ok then return false end
	saveTaskDue(t, dateStr)
	return true
end

-- Validate and save a title. Unchanged titles are not written.
local function commitTitle(t, text)
	local s = ((text or ""):match("^%s*(.-)%s*$"))
	if s == "" then
		noctalia.notify(APP, "The title cannot be empty")
		return false
	end
	if s ~= tostring(t.summary) then saveTaskTitle(t, s) end
	return true
end

-- The tag editor: filter-and-add input + suggestion chips + removable tags + due date.
local function tagEditor(t)
	local children = {}
	-- Title: Enter saves; text typed but not submitted is saved on "Done".
	children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "pencil", size = 14, color = "on_surface/0.6" }),
		ui.input({
			key = "title-" .. tostring(t.href), value = tostring(t.summary or ""),
			placeholder = "Task title", controlSize = "sm",
			flexGrow = 1,
			onChange = function(text)
				titleDraft = { href = t.href, text = tostring(text or "") }
			end,
			onSubmit = function(val)
				if commitTitle(t, val) then titleDraft = nil end
				render()
			end,
		}),
	})
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
			placeholder = "e.g. 31.10, fri, +3, 2w (empty clears)", controlSize = "sm",
			flexGrow = 1,
			-- remember the text only; no render() here, so typing is not disturbed
			onChange = function(text)
				dueDraft = { href = t.href, text = tostring(text or "") }
			end,
			onSubmit = function(val)
				-- on a format error keep what was typed, so it can be corrected
				if commitDue(t, val) then
					dueDraft = nil
					dueSeed = dueSeed + 1
					render()
				end
			end,
		}),
	})

	-- Quick dates: click to set and save at once.
	local picks = {}
	for _, c in ipairs(dueChips(todayNum())) do
		picks[#picks + 1] = tagChip(c.label, function()
			dueDraft = nil
			dueSeed = dueSeed + 1
			saveTaskDue(t, c.ymd)
		end)
	end
	for i = 1, #picks, CHIPS_PER_ROW do
		local line = {}
		for j = i, math.min(i + CHIPS_PER_ROW - 1, #picks) do line[#line + 1] = picks[j] end
		children[#children + 1] = ui.row({ gap = 4, align = "center" }, line)
	end

	children[#children + 1] = ui.button({
		text = "Done", variant = "ghost",
		onClick = function()
			local tDraft, dDraft = titleDraft, dueDraft
			titleDraft, dueDraft = nil, nil

			-- what is pending for this task
			local newTitle, newDue, hasDue = nil, nil, false
			if tDraft and tDraft.href == t.href then
				local s = (tDraft.text:match("^%s*(.-)%s*$"))
				if s == "" then
					noctalia.notify(APP, "The title cannot be empty")
					titleDraft, dueDraft = tDraft, dDraft -- keep the editor open to fix it
					return
				end
				if s ~= tostring(t.summary) then newTitle = s end
			end
			if dDraft and dDraft.href == t.href and dDraft.text ~= prefilled then
				local ok, dateStr = parseDue(dDraft.text)
				if not ok then
					titleDraft, dueDraft = tDraft, dDraft -- keep the editor open to fix it
					return
				end
				newDue, hasDue = dateStr, true
				dueSeed = dueSeed + 1
			end

			editingTask = nil
			tagQuery = ""
			if newTitle and hasDue then
				saveTaskTitleAndDue(t, newTitle, newDue)
			elseif newTitle then
				saveTaskTitle(t, newTitle)
			elseif hasDue then
				saveTaskDue(t, newDue)
			else
				render()
			end
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
			titleDraft = nil
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


-- A recently completed task: dimmed, with an undo arrow instead of the circle.
local function doneRow(task)
	return ui.row({
		key = "done-" .. tostring(task.href or task.summary),
		gap = 8,
		align = "center",
		opacity = 0.45,
	}, {
		ui.button({
			glyph = "arrow-back-up", variant = "ghost", tooltip = "Undo",
			onClick = function() undoComplete(task) end,
		}),
		ui.label({ text = tostring(task.summary), maxLines = 1, flexGrow = 1 }),
	})
end

function onRefreshClicked() requestRefresh() end

function onAddSubmit(value)
	addTask(value)
	inputSeed = inputSeed + 1
	render()
end

render = function()
	local shown = math.min(#visible, MAX_ROWS)

	local header = ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = "Tasks", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
		ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
	})

	local input = ui.input({
		key = "newtask-" .. inputSeed, value = "", focus = true,
		placeholder = "New task… (Enter to add; !fri = due Friday)", onSubmit = "onAddSubmit",
	})

	local rows = {}
	if #visible == 0 then
		rows[1] = ui.column({ align = "center", gap = 6, paddingV = 24 }, {
			ui.glyph({ name = "check", size = 32, color = "primary" }),
			ui.label({ text = "All done!", color = "on_surface/0.6" }),
		})
	else
		for i = 1, shown do
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

	-- recently completed tasks: at the end, until their time is up
	for _, t in ipairs(doneRows) do
		rows[#rows + 1] = doneRow(t)
	end

	panel.render(ui.column({ gap = 8, padding = 12, height = ROOT_HEIGHT }, {
		header,
		input,
		ui.separator({}),
		ui.scroll({ gap = 4, flexGrow = 1 }, rows),
	}))
end

function onOpen(_context)
	local ok, err = pcall(function()
		rebuildVisible() -- also drops expired entries and restarts the ticks if needed
		render()
	end)
	if not ok then report("onOpen-render", err) end
	requestRefresh()
end

-- Called every second while completed tasks are waiting to expire.
function update()
	if pruneRecent() then
		rebuildVisible()
		render()
	end
	if next(recent) == nil then
		pcall(panel.setWantsSecondTicks, false)
	end
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
