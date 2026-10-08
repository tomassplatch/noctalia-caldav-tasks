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

-- The calendar URL found by the last successful sync is passed back on the
-- next one, so discovery (several requests) only runs once per configuration.
local known = { key = nil, url = nil }

local syncing = false
local syncStarted = 0
local pending = false -- a refresh was requested while a sync was running

local runFetch

local function finishSync()
	syncing = false
	if pending then
		pending = false
		runFetch()
	end
end

runFetch = function()
	if syncing and os.time() - syncStarted < 90 then
		pending = true
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
	local urlArg = calUrl
	if known.key == key and known.url then urlArg = known.url end

	publishStatus("Syncing...")
	syncing = true
	syncStarted = os.time()
	pending = false

	local launched = noctalia.runAsync(
		{ "python3", script, server, user, pass, cal, urlArg },
		function(r)
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

				local tasks = data.tasks or {}
				local open = 0
				for _, t in ipairs(tasks) do
					if not t.done then open = open + 1 end
				end

				known.key = key
				known.url = data.url
				noctalia.state.set("dav", { server = server, calUrl = data.url })
				publishStatus(("Synced %s — %d open (%d total)")
					:format(os.date("%H:%M:%S"), open, #tasks))
				noctalia.state.set("tasks", tasks)
			end)

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
	runFetch()
end

local interval = tonumber(noctalia.getConfig("interval")) or 120
noctalia.setUpdateInterval(math.max(15, interval) * 1000)

noctalia.state.watch("refreshRequest", function()
	runFetch()
end)

function update()
	runFetch()
end
