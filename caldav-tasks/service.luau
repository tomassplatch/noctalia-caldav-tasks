--!nonstrict
-- Background service: delegates CalDAV discovery + fetch + parse to
-- fetch_tasks.py (child process, immune to the VM CPU budget), then
-- publishes the results for the panel and the bar widget.

local APP = "CalDAV Tasks"

local function notify(msg)
	noctalia.notify(APP, msg)
end

local function publishStatus(s)
	noctalia.state.set("status", s or "(no status)")
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

local syncing = false
local syncStarted = 0
local pending = false      -- a refresh was requested while a sync was running
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
-- after a panel edit). force = false: timer tick, may skip if unchanged.
runFetch = function(force)
	force = force == true

	if syncing and os.time() - syncStarted < 90 then
		pending = true
		pendingForce = pendingForce or force
		return
	end

	local server = (cfgStr("server")):gsub("/+$", "")
	local user = cfgStr("username")
	local pass = cfgStr("password")
	local cal = cfgStr("calendar")
	local calUrl = cfgStr("calendar_url")

	if #server == 0 or #user == 0 or #pass == 0 then
		publishStatus("Missing server/username/password config")
		return
	end

	local script = scriptPath()
	if not script then
		publishStatus("Could not locate the plugin directory")
		return
	end

	local key = table.concat({ server, user, cal, calUrl }, "\n")
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

function onConfigChanged()
	noctalia.setUpdateInterval(syncInterval() * 1000)
	noteSuccess()
	runFetch(true)
end

noctalia.setUpdateInterval(syncInterval() * 1000)

-- Panel open, refresh button, and every panel edit all go through here:
-- always a full fetch, so optimistic edits in the panel get corrected.
noctalia.state.watch("refreshRequest", function()
	runFetch(true)
end)

-- Timer tick: cheap check, and no retry while backing off.
function update()
	if os.time() < retryAt then return end
	runFetch(false)
end
