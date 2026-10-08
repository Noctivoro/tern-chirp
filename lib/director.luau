--!strict
-- Asks Jev how Tern should sound about a finished agent turn. Jev only picks
-- among the options below (mood, voice, pitch, pace, energy, whether you are
-- asked something) and returns probabilities; voice.compose turns them into
-- beeps. Pure functions: the window half does the HTTP and JSON.

local voice = require("./voice")

local M = {}

M.URL = "https://api.typesafe.ai/v1/systemone"
M.MODEL = "jev-latest"

export type Turn = {
	-- "waiting_input" (the agent is blocked on you), "idle" (turn finished) or "test".
	event: string,
	agent: string?,
	project: string?,
	turn_ms: number?,
	text: string,
}

local MOODS: { [string]: string } = {
	curious = "asks the user a question or wants their opinion",
	eager = "ready to go and wants a go-ahead or approval to continue",
	proud = "finished the work and it went well",
	excited = "big win, great news, everything passing",
	calm = "routine status, nothing special",
	worried = "something failed, broke, or is blocked",
	sheepish = "apologises, made a mistake, or could not do what was asked",
}

local VOICES: { [string]: string } = {
	chirp = "bright rising tweets: friendly and upbeat",
	blip = "short crisp beeps: matter-of-fact",
	bubble = "soft falling bloops: relaxed, wrapping up",
	robot = "buzzy metallic: technical, logs, errors",
	chatter = "quick warbling: a long report with a lot to say",
	whisper = "soft and airy: a small, low-stakes note",
}

local LEVELS = 5

-- At most ~900 characters: the opening and the end, where questions sit.
local function excerpt(text: string): string
	local ok = utf8.len(text) ~= nil
	if not ok then
		text = string.gsub(text, "[\128-\255]", "")
	end
	local chars = utf8.len(text) :: number
	if chars <= 900 then
		return text
	end
	local head_end = (utf8.offset(text, 251) :: number) - 1
	local tail_start = utf8.offset(text, chars - 599) :: number
	return string.sub(text, 1, head_end) .. " … " .. string.sub(text, tail_start)
end

-- The JSON body (as a table) for POST M.URL.
function M.request(turn: Turn): { [string]: any }
	local framing = "Tern is a terminal app with a small beeping robot voice, like R2-D2. "
		.. "An AI coding agent just "
		.. (if turn.event == "waiting_input" then "stopped to wait for the user" else "finished its turn")
		.. ". Tern beeps to tell the user. "
	return {
		model = M.MODEL,
		state = {
			event = turn.event,
			agent = turn.agent or "agent",
			project = turn.project,
			turn_seconds = if turn.turn_ms then math.floor(turn.turn_ms / 1000) else nil,
			message = excerpt(turn.text),
		},
		questions = {
			mood = {
				type = "choice",
				instructions = framing .. "Which mood should the robot express about this message?",
				criteria = MOODS,
			},
			voice = {
				type = "choice",
				instructions = framing .. "Which robot voice suits this message?",
				criteria = VOICES,
			},
			pitch = {
				type = "score",
				instructions = framing .. "How high should the voice be? Higher is lighter and happier, lower is serious.",
				criteria = { "very low", "low", "medium", "high", "very high" },
			},
			rate = {
				type = "score",
				instructions = framing .. "How fast should it beep? Urgent or excited is fast, thoughtful is slow.",
				criteria = { "very slow", "slow", "medium", "fast", "very fast" },
			},
			energy = {
				type = "score",
				instructions = framing .. "How much energy should it have?",
				criteria = { "sleepy", "low", "medium", "lively", "bursting" },
			},
			asks = {
				type = "noul",
				instructions = "The message asks the user to answer, decide, approve, or provide something.",
			},
		},
	}
end

local function dist(answer: any, keys: { string }): { [string]: number }?
	if type(answer) ~= "table" or type(answer.probabilities) ~= "table" then
		return nil
	end
	local out = {}
	for _, k in keys do
		local v = answer.probabilities[k]
		if type(v) ~= "number" then
			return nil
		end
		out[k] = math.clamp(v, 0, 1)
	end
	return out
end

local function top(d: { [string]: number }, keys: { string }): string
	local best, bestp = keys[1], -1
	for _, k in keys do
		if d[k] > bestp then
			best, bestp = k, d[k]
		end
	end
	return best
end

-- Expected score of a five-level answer, as 0..1.
local function level(answer: any): number?
	if type(answer) ~= "table" then
		return nil
	end
	if type(answer.score) == "number" then
		return math.clamp(answer.score / (LEVELS - 1), 0, 1)
	end
	if type(answer.probabilities) ~= "table" then
		return nil
	end
	local sum = 0
	for i = 0, LEVELS - 1 do
		local v = answer.probabilities[tostring(i)]
		if type(v) ~= "number" then
			return nil
		end
		sum += i * v
	end
	return math.clamp(sum / (LEVELS - 1), 0, 1)
end

-- A reading from a decoded 200 response; nil when it is malformed.
function M.parse(body: any): voice.Reading?
	if type(body) ~= "table" or type(body.answers) ~= "table" then
		return nil
	end
	local a = body.answers
	local moods = dist(a.mood, voice.MOODS)
	local voices = dist(a.voice, voice.VOICES)
	local pitch, rate, energy = level(a.pitch), level(a.rate), level(a.energy)
	local asks = if type(a.asks) == "table" and type(a.asks.noul) == "number" then a.asks.noul else nil
	if not (moods and voices and pitch and rate and energy and asks) then
		return nil
	end
	local confidence = if type(a.mood.confidence) == "number" then a.mood.confidence else 1
	return {
		mood = top(moods, voice.MOODS),
		moods = moods,
		voice = top(voices, voice.VOICES),
		voices = voices,
		pitch = pitch,
		rate = rate,
		energy = energy,
		asks = math.clamp(asks, 0, 1),
		confidence = math.clamp(confidence, 0, 1),
		source = "jev",
		model = if type(body.model) == "string" then body.model else nil,
	}
end

local function one(keys: { string }, pick: string): { [string]: number }
	local d = {}
	for _, k in keys do
		d[k] = if k == pick then 1 else 0
	end
	return d
end

-- The voice without Jev (no key, offline, API error): what the agent state
-- and the closing punctuation say, nothing more.
function M.fallback(turn: Turn): voice.Reading
	local trimmed = string.match(turn.text, "^(.-)%s*$") or ""
	local asks = turn.event == "waiting_input" or string.sub(trimmed, -1) == "?"
	local mood = if asks then "curious" else "calm"
	local v = if asks then "chirp" else "bubble"
	return {
		mood = mood,
		moods = one(voice.MOODS, mood),
		voice = v,
		voices = one(voice.VOICES, v),
		pitch = 0.5,
		rate = 0.5,
		energy = 0.5,
		asks = if asks then 1 else 0,
		confidence = 1,
		source = "local",
		model = nil,
	}
end

return M
