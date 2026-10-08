--!strict
-- The window half: watches agent blocks, and when one finishes a turn or
-- stops to wait for you, asks Jev how that turn feels and beeps it.
--
-- Agent state has no lifecycle event (tern.on covers shells, panes, tabs and
-- focus), so this reads cx.agents:list(), an in-memory replica, every
-- POLL_MS. Every window of a session sees the same agents, so a shared
-- tern.kv record keeps a turn from being spoken once per window.

local director = require("./lib/director")
local synth = require("./lib/synth")
local voice = require("./lib/voice")

local POLL_MS = 700
-- A turn shorter than this in the focused pane stays quiet: you watched it.
local FOCUSED_QUIET_MS = 12000
local JEV_TIMEOUT_MS = 3000
local MAX_QUEUE = 3

local SAMPLE = "I added the redirect map and the preview build passes. Should I push it to main, or open a PR for review first?"

type Agent = { state: string, since: number }
type Spoken = { reading: voice.Reading, text: string, label: string }

local agents: { [number]: Agent } = {}
local primed = false
local key: string? = nil
local key_checked = false
local queue: { Spoken } = {}
local playing = false
local slot = 0
local last: Spoken? = nil

local function enabled(): boolean
	return tern.kv.get("enabled") ~= false
end

local function volume(): number
	local v = tern.kv.get("volume")
	return if type(v) == "number" then math.clamp(v, 0.05, 1) else 0.2
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function basename(path: string?): string?
	return if path then string.match(path, "([^/\\]+)[/\\]*$") else nil
end

local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end

local function tmpdir(): string
	local dir = tern.getenv("TMPDIR") or "/tmp"
	return (string.gsub(dir, "/+$", ""))
end

local function player(path: string): { string }?
	local platform = tern.runtime.os
	if platform == "macos" then
		return { "/usr/bin/afplay", "-v", string.format("%.2f", volume()), path }
	elseif platform == "linux" then
		return { "paplay", "--volume=" .. math.floor(volume() * 65536), path }
	end
end

local function play_next()
	if playing then
		return
	end
	local item = table.remove(queue, 1)
	if not item then
		return
	end
	local notes, fx, seed = voice.compose(item.reading, item.text)
	local started = tern.now()
	local wav, secs = synth.render(notes, fx, seed)
	local render_ms = tern.now() - started
	slot = slot % 4 + 1
	local path = tmpdir() .. "/tern-chirp-" .. slot .. ".wav"
	tern.fs.write(path, wav)
	last = item
	local r = item.reading
	tern.kv.set("last", {
		label = item.label, mood = r.mood, voice = r.voice, pitch = r.pitch, rate = r.rate,
		energy = r.energy, asks = r.asks, confidence = r.confidence, source = r.source,
		model = r.model or tern.json.null, seconds = secs, render_ms = render_ms, at = os.time(),
	})
	local argv = player(path)
	if not argv then
		tern.log.warn("chirp: no audio player for", tern.runtime.os)
		return
	end
	playing = true
	tern.process.run(argv, { timeout_ms = 10000 }, function(res: ProcessResult)
		playing = false
		if res.status ~= 0 then
			tern.log.warn("chirp: player exited", res.status, res.stderr)
		end
		play_next()
	end)
end

local function speak(reading: voice.Reading, text: string, label: string)
	if #queue >= MAX_QUEUE then
		table.remove(queue, 1)
	end
	table.insert(queue, { reading = reading, text = text, label = label })
	play_next()
end

-- The TypeSafe key: TYPESAFE_API_KEY, else the `typesafe-api-key` Keychain
-- item. Read once per window; never logged.
local function with_key(cb: (string?) -> ())
	if key_checked then
		cb(key)
		return
	end
	local env = str(tern.getenv("TYPESAFE_API_KEY"))
	if env then
		key, key_checked = env, true
		cb(key)
		return
	end
	if tern.runtime.os ~= "macos" then
		key_checked = true
		cb(nil)
		return
	end
	tern.process.run(
		{ "/usr/bin/security", "find-generic-password", "-s", "typesafe-api-key", "-a", "default", "-w" },
		{ timeout_ms = 5000 },
		function(res: ProcessResult, cx: WindowCx?)
			key_checked = true
			key = if res.status == 0 then str((string.gsub(res.stdout, "%s+$", ""))) else nil
			if not key and cx then
				cx:toast("info", "Chirp: no TypeSafe key, so the voice skips Jev", "Set TYPESAFE_API_KEY or Keychain item typesafe-api-key")
			end
			cb(key)
		end
	)
end

-- Jev's reading of a turn, or the local one when Jev is unavailable.
local function judge(turn: director.Turn, cb: (voice.Reading) -> ())
	with_key(function(k: string?)
		if not k then
			cb(director.fallback(turn))
			return
		end
		local body = tern.json.encode(director.request(turn))
		local function attempt(retry: boolean)
			tern.fetch(director.URL, {
				method = "POST",
				headers = { Authorization = "Bearer " .. k, ["Content-Type"] = "application/json", Accept = "application/json" },
				body = body,
				timeout_ms = JEV_TIMEOUT_MS,
			}, function(res: FetchResult)
				if res.status == 200 then
					local ok, decoded = pcall(tern.json.decode, res.body)
					local reading = if ok then director.parse(decoded) else nil
					if reading then
						cb(reading)
						return
					end
					tern.log.warn("chirp: malformed Jev answer")
				elseif retry and (res.status == 429 or res.status == 503 or res.status == 529) then
					-- TypeSafe answers 529 when overloaded; one quick retry.
					tern.timer(300, function()
						attempt(false)
					end)
					return
				else
					tern.log.warn("chirp: Jev request failed", res.status, res.error or "")
				end
				cb(director.fallback(turn))
			end)
		end
		attempt(true)
	end)
end

-- The agent's program name ("omp"), not its whole command line.
local function agent_name(a: AgentBlock): string?
	local command = str(a.command)
	return (command and basename(string.match(command, "^(%S+)"))) or str(a.model)
end

local function announce(a: AgentBlock, turn_ms: number?)
	local text = str(a.last_message) or ""
	-- One window speaks a given turn; the others see the record and stay quiet.
	local sig = string.format("%s:%d", a.state, hash(text))
	local pane = tostring(a.pane)
	local now = os.time()
	local said = tern.kv.get("said")
	local fresh: { [string]: any } = {}
	if type(said) == "table" then
		for p, rec in said do
			if type(rec) == "table" and type(rec.at) == "number" and now - rec.at < 60 then
				fresh[p] = rec
			end
		end
	end
	if fresh[pane] and fresh[pane].sig == sig then
		return
	end
	fresh[pane] = { sig = sig, at = now }
	tern.kv.set("said", fresh)

	local agent = agent_name(a)
	local project = basename(str(a.cwd))
	local turn: director.Turn = { event = a.state, agent = agent, project = project, turn_ms = turn_ms, text = text }
	judge(turn, function(reading: voice.Reading)
		speak(reading, text, (agent or "agent") .. (if project then " · " .. project else ""))
	end)
end

local function tick(cx: WindowCx)
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		local now = tern.now()
		local focused = cx.session:focused()
		local seen: { [number]: boolean } = {}
		for _, a in list do
			seen[a.pane] = true
			local prev = agents[a.pane]
			if not prev then
				agents[a.pane] = { state = a.state, since = now }
			elseif prev.state ~= a.state then
				local turn_ms = if prev.state == "working" then now - prev.since else nil
				agents[a.pane] = { state = a.state, since = now }
				local wants = (a.state == "waiting_input")
					or (a.state == "idle" and prev.state == "working")
				local watched = a.pane == focused and turn_ms ~= nil and turn_ms < FOCUSED_QUIET_MS
				if primed and wants and not watched and enabled() then
					announce(a, turn_ms)
				end
			end
		end
		for pane in agents do
			if not seen[pane] then
				agents[pane] = nil
			end
		end
		primed = true
	else
		tern.log.warn("chirp: agents:list failed", list)
	end
	tern.timer(POLL_MS, function(next_cx: WindowCx?)
		if next_cx then
			tick(next_cx)
		end
	end)
end

-- Start watching once this half loads. A timer, not `window_start`: that
-- event fires once per window, so a plugin reload would never restart it.
tern.timer(0, function(cx: WindowCx?)
	if cx then
		tick(cx)
	end
end)

local function focused_agent(cx: WindowCx): AgentBlock?
	local id = cx.session:focused()
	for _, a in cx.agents:list() do
		if a.pane == id then
			return a
		end
	end
	return nil
end

tern.command({
	id = "toggle",
	title = "Chirp: Mute or unmute the voice",
	icon = "bell",
	run = function(cx: WindowCx)
		local on = not enabled()
		tern.kv.set("enabled", on)
		cx:toast(if on then "success" else "info", if on then "Chirp is listening" else "Chirp is muted")
	end,
})

tern.command({
	id = "test",
	title = "Chirp: Say the focused agent's last turn",
	icon = "bell",
	run = function(cx: WindowCx)
		local a = focused_agent(cx)
		local text = (a and str(a.last_message)) or SAMPLE
		local label = if a then "focused agent" else "sample"
		judge({ event = "test", agent = a and agent_name(a), project = basename(a and str(a.cwd)), text = text }, function(reading)
			speak(reading, text, label)
		end)
	end,
})

tern.command({
	id = "replay",
	title = "Chirp: Replay the last chirp",
	icon = "bell",
	available = function(_cx: WindowCx): boolean
		return last ~= nil
	end,
	run = function(_cx: WindowCx)
		if last then
			speak(last.reading, last.text, last.label)
		end
	end,
})

tern.command({
	id = "explain",
	title = "Chirp: What did that chirp mean?",
	icon = "bell",
	available = function(_cx: WindowCx): boolean
		return last ~= nil
	end,
	run = function(cx: WindowCx)
		local item = last
		if not item then
			return
		end
		local r = item.reading
		local asks = if r.asks >= 0.5 then "wants your answer" else "just letting you know"
		cx:toast(
			"info",
			string.format("%s: %s, %s voice, %s", item.label, r.mood, r.voice, asks),
			string.format(
				"pitch %.2f · pace %.2f · energy %.2f · sure %.0f%% · %s",
				r.pitch, r.rate, r.energy, r.confidence * 100, if r.source == "jev" then (r.model or "jev") else "local, no Jev"
			)
		)
	end,
})

local function nudge(cx: WindowCx, by: number)
	local v = math.clamp(volume() + by, 0.05, 1)
	tern.kv.set("volume", v)
	cx:toast("info", string.format("Chirp volume %d%%", math.floor(v * 100 + 0.5)))
	if last then
		speak(last.reading, last.text, last.label)
	end
end

tern.command({
	id = "louder",
	title = "Chirp: Louder",
	icon = "bell",
	run = function(cx: WindowCx)
		nudge(cx, 0.15)
	end,
})

tern.command({
	id = "softer",
	title = "Chirp: Softer",
	icon = "bell",
	run = function(cx: WindowCx)
		nudge(cx, -0.15)
	end,
})
