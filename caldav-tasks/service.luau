--!nonstrict
-- Background service: delegates CalDAV discovery + fetch + parse to
-- fetch_tasks.py (child process, immune to the VM CPU budget), then
-- publishes the results for the panel and the bar widget.

local APP = "CalDAV Tasks"

local function log(msg)
	pcall(noctalia.log, "[caldav-tasks] " .. tostring(msg))
end

local function notify(msg)
	noctalia.notify(APP, msg)
end

local function publishStatus(s)
	s = s or "(no status)"
	-- anything that is not a normal progress message also goes to Noctalia's log
	if not (s:find("^Synced") or s:find("^Syncing")) then log(s) end
	noctalia.state.set("status", s)
end

local function logFile(name, content)
	pcall(function()
		noctalia.writeFile(noctalia.pluginDataDir() .. "/" .. name, content)
	end)
end

local function cfgStr(key)
	local v = noctalia.getConfig(key)
	if v == nil then return "" end
	return tostring(v)
end

-- fetch_tasks.py lives next to this script, wherever the plugin is installed.
local function scriptPath()
	local dir = noctalia.pluginDir()
	if type(dir) ~= "string" or dir == "" then return nil end
	if dir:sub(-1) ~= "/" then dir = dir .. "/" end
	return dir .. "fetch_tasks.py"
end

local function syncInterval()
	return math.max(15, tonumber(noctalia.getConfig("interval")) or 120)
end

-- Noctalia's own offline mode (needs plugin_api = 26; otherwise: not offline).
local function offlineMode()
	local ok, v = pcall(noctalia.getSetting, "shell.offline_mode")
	return ok and v == true
end

local function readConfig()
	local server = (cfgStr("server"):gsub("/+$", ""))
	local user = cfgStr("username")
	local pass = cfgStr("password")
	local cal = cfgStr("calendar")
	local calUrl = cfgStr("calendar_url")
	local key = table.concat({ server, user, cal, calUrl }, "\n")
	return server, user, pass, cal, calUrl, key
end

-- Back off while syncs keep failing (offline, server down, bad credentials).
-- Manual refreshes and config changes ignore this.
local failures = 0
local retryAt = 0

local function noteSuccess()
	failures = 0
	retryAt = 0
end

local function noteFailure()
	failures = failures + 1
	local wait = math.min(1800, syncInterval() * (2 ^ math.min(failures, 5)))
	retryAt = os.time() + math.floor(wait)
end

-- The calendar URL and change marker (ctag) from the last successful sync are
-- passed back on the next one: discovery runs once per configuration, and an
-- unchanged calendar skips the full download.
local known = { key = nil, url = nil, ctag = nil, open = 0, total = 0 }

-- ===== on-disk cache (tasks survive a restart / are available offline) =====

local lastCacheJson = nil

local function cachePath()
	local dir = noctalia.pluginDataDir()
	if type(dir) ~= "string" or dir == "" then return nil end
	return dir .. "/cache.json"
end

local function saveCache(key, url, ctag, tasks)
	local path = cachePath()
	if not path then return end
	local encoded = noctalia.json.encode({ key = key, url = url, ctag = ctag, tasks = tasks })
	if type(encoded) ~= "string" or encoded == lastCacheJson then return end
	lastCacheJson = encoded
	pcall(noctalia.writeFile, path, encoded)
end

local function loadCache()
	local path = cachePath()
	if not path then return end
	local raw = noctalia.readFile(path)
	if type(raw) ~= "string" or raw == "" then return end
	local data = noctalia.json.decode(raw)
	local server, _, _, _, _, key = readConfig()
	if type(data) ~= "table" or data.key ~= key
		or type(data.tasks) ~= "table" or type(data.url) ~= "string" then
		return
	end
	local open = 0
	for _, t in ipairs(data.tasks) do
		if not t.done then open = open + 1 end
	end
	known.key = key
	known.url = data.url
	known.ctag = (type(data.ctag) == "string" and data.ctag ~= "") and data.ctag or nil
	known.open = open
	known.total = #data.tasks
	lastCacheJson = raw
	noctalia.state.set("dav", { server = server, calUrl = data.url })
	noctalia.state.set("tasks", data.tasks)
	publishStatus("Syncing... (showing cached tasks)")
end

-- ===== cheap change check without starting Python =====

local PROPFIND_CTAG = '<?xml version="1.0"?>'
	.. '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop>'
	.. "<cs:getctag/><d:sync-token/></d:prop></d:propfind>"

-- cb(ctag): the calendar's change marker, or nil when it could not be read
-- (then the caller simply falls back to fetch_tasks.py).
local function quickCtag(calUrl, user, pass, cb)
	local started = noctalia.http({
		url = calUrl,
		method = "PROPFIND",
		body = PROPFIND_CTAG,
		headers = { "Content-Type: application/xml; charset=utf-8", "Depth: 0" },
		basic_username = user,
		basic_password = pass,
	}, function(resp)
		local ctag = nil
		if resp and (resp.ok or resp.status == 207) and type(resp.body) == "string" then
			ctag = resp.body:match("getctag[^>]*>%s*([^<]-)%s*<")
				or resp.body:match("sync%-token[^>]*>%s*([^<]-)%s*<")
			if ctag == "" then ctag = nil end
		end
		cb(ctag)
	end)
	if not started then cb(nil) end
end

-- ===== sync =====

local syncing = false
local syncStarted = 0
local pending = false -- a refresh was requested while a sync was running
local pendingForce = false

local runFetch

local function finishSync()
	syncing = false
	if pending then
		local force = pendingForce
		pending = false
		pendingForce = false
		runFetch(force)
	end
end

-- force = true: always download and republish (manual refresh, config change,
-- panel edits). force = false: timer tick, may skip if unchanged.
runFetch = function(force)
	force = force == true

	if syncing and os.time() - syncStarted < 90 then
		pending = true
		pendingForce = pendingForce or force
		return
	end

	local server, user, pass, cal, calUrl, key = readConfig()

	if #server == 0 or #user == 0 or #pass == 0 then
		publishStatus("Missing server/username/password config")
		return
	end

	local script = scriptPath()
	if not script then
		publishStatus("Could not locate the plugin directory")
		return
	end

	if known.key ~= key then known.ctag = nil end

	local urlArg = calUrl
	if known.key == key and known.url then urlArg = known.url end

	local ctagArg = ""
	if not force and known.key == key and known.ctag then ctagArg = known.ctag end

	if force then publishStatus("Syncing...") end
	syncing = true
	syncStarted = os.time()
	pending = false
	pendingForce = false

	-- Full sync through fetch_tasks.py (it does its own ctag check as well).
	local function launch()
		local launched = noctalia.runAsync(
			{ "python3", script, server, user, pass, cal, urlArg, ctagArg },
			function(r)
				local good = false
				local ok, err = pcall(function()
					if type(r) ~= "table" then
						known.url = nil
						publishStatus("Unexpected runAsync result: " .. tostring(r))
						return
					end
					if r.timedOut then
						publishStatus("fetch_tasks.py timed out")
						return
					end
					if r.exitCode ~= 0 or not r.stdout or #r.stdout == 0 then
						known.url = nil
						publishStatus("fetch_tasks.py failed: "
							.. tostring(r.stderr and r.stderr:match("[^\r\n]+") or ("exit " .. tostring(r.exitCode))))
						return
					end

					local data = noctalia.json.decode(r.stdout)
					if not data then
						publishStatus("fetch script produced invalid JSON")
						return
					end
					if data.ok == false then
						known.url = nil -- rediscover next time
						publishStatus(tostring(data.message))
						return
					end

					local ctag = nil
					if type(data.ctag) == "string" and data.ctag ~= "" then ctag = data.ctag end

					if data.unchanged then
						-- Calendar did not change: keep the published tasks as they are.
						known.key = key
						known.url = data.url
						known.ctag = ctag
						publishStatus(("Synced %s — %d open (%d total)")
							:format(os.date("%H:%M:%S"), known.open, known.total))
						good = true
						return
					end

					local tasks = data.tasks or {}
					local open = 0
					for _, t in ipairs(tasks) do
						if not t.done then open = open + 1 end
					end

					known.key = key
					known.url = data.url
					known.ctag = ctag
					known.open = open
					known.total = #tasks
					noctalia.state.set("dav", { server = server, calUrl = data.url })
					publishStatus(("Synced %s — %d open (%d total)")
						:format(os.date("%H:%M:%S"), open, #tasks))
					noctalia.state.set("tasks", tasks)
					saveCache(key, data.url, ctag, tasks)
					good = true
				end)

				if good then noteSuccess() else noteFailure() end

				if not ok then
					publishStatus("Sync error: " .. tostring(err))
					logFile("error.log", os.date("!%Y-%m-%d %H:%M:%S ") .. tostring(err) .. "\n")
					notify("Sync crashed — see error.log")
				end
				finishSync()
			end)

		if not launched then
			syncing = false
			publishStatus("Could not launch fetch_tasks.py — is python3 installed?")
		end
	end

	if ctagArg ~= "" and known.url then
		-- Timer tick on a known calendar: ask the server first, without Python.
		quickCtag(known.url, user, pass, function(ctag)
			log("quick ctag check: " .. tostring(ctag) .. " (known: " .. tostring(known.ctag) .. ")")
			if ctag ~= nil and ctag == known.ctag then
				publishStatus(("Synced %s — %d open (%d total)")
					:format(os.date("%H:%M:%S"), known.open, known.total))
				noteSuccess()
				finishSync()
			else
				launch()
			end
		end)
	else
		launch()
	end
end

function onConfigChanged()
	noctalia.setUpdateInterval(syncInterval() * 1000)
	noteSuccess()
	runFetch(true)
end

noctalia.setUpdateInterval(syncInterval() * 1000)
pcall(loadCache)

-- Panel open, refresh button, and every panel edit all go through here:
-- always a full fetch, so optimistic edits in the panel get corrected.
noctalia.state.watch("refreshRequest", function()
	runFetch(true)
end)

-- Timer tick: cheap check, no retry while backing off, nothing in offline mode.
function update()
	if os.time() < retryAt then return end
	if offlineMode() then return end
	runFetch(false)
end
