--!strict
-- Turns a reading (Jev's judgement of the turn) into one robot syllable, or
-- two when the feeling is mixed: what happened, then the follow-up. The mood
-- shapes the pitch (a question rises, a win arcs up, trouble droops), the
-- voice picks the timbre, and the agent's words nudge pitch and tone so the
-- same message always sounds the same.

local synth = require("./synth")

local M = {}

export type Reading = {
	-- Top mood and the whole distribution over MOODS.
	mood: string,
	moods: { [string]: number },
	-- Top voice and the whole distribution over VOICES.
	voice: string,
	voices: { [string]: number },
	-- Expected scores mapped to 0..1.
	pitch: number,
	rate: number,
	energy: number,
	-- Probability the message asks the user for something.
	asks: number,
	-- How sure the mood judgement was, 0..1; low confidence wobbles the voice.
	confidence: number,
	-- "jev" or "local" (no key or the API failed), and the model that judged.
	source: string,
	model: string?,
}

M.MOODS = { "curious", "eager", "proud", "excited", "calm", "worried", "sheepish" }
M.VOICES = { "chirp", "blip", "bubble", "robot", "chatter", "whisper" }

-- Pitch shape per mood: start and end in semitones, arc, length factor.
local CONTOUR: { [string]: { number } } = {
	curious = { 0, 7, 1, 1.0 }, -- up: "hm?"
	eager = { 0, 5, 3, 0.85 }, -- quick lift
	proud = { 0, 2, 5, 1.0 }, -- arc: "ta-da"
	excited = { 0, 12, 4, 0.8 }, -- octave leap
	calm = { 0, -2, 1.5, 1.25 }, -- gentle settle
	worried = { 0, -5, -1, 1.1 }, -- droop
	sheepish = { 2, -7, 2, 1.2 }, -- up, then slides away
}

-- Moods that already rise, so a question needs no second syllable.
local ASKING: { [string]: boolean } = { curious = true, eager = true }

-- Pentatonic offsets the message's words pick from.
local OFFSETS = { 0, 2, 4, 7, 9 }

-- The first vowel of the key word opens or closes the tone, like a mouth shape.
local VOWEL: { [string]: number } = { a = 1.0, e = 1.35, i = 1.8, o = 0.75, u = 0.6, y = 1.5 }

-- A second mood at least this likely makes the sound two syllables.
M.MIXED = 0.25

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end

local function rng(seed: number): () -> number
	local x = bit32.bor(seed % 4294967296, 1)
	return function(): number
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		return x / 4294967296
	end
end

-- The words of the key phrase: the last question when there is one, else the
-- first sentence.
function M.phrase(text: string): { string }
	local clean = string.gsub(text, "```.-```", " ")
	clean = string.gsub(clean, "`[^`]*`", " ")
	clean = string.gsub(clean, "%b()", " ")
	clean = string.gsub(clean, "[%*_#>%[%]|~]", " ")
	local sentences = {}
	for s in string.gmatch(clean .. ".", "([^%.!%?\n]+[%.!%?\n])") do
		if string.find(s, "%a%a") then
			table.insert(sentences, s)
		end
	end
	local chosen = sentences[1]
	for i = #sentences, 1, -1 do
		if string.sub(sentences[i], -1) == "?" then
			chosen = sentences[i]
			break
		end
	end
	local words = {}
	if chosen then
		for w in string.gmatch(chosen, "%a[%w']*") do
			table.insert(words, string.lower(w))
		end
	end
	return words
end

local function second(dist: { [string]: number }, top: string): (string?, number)
	local best, bestp = nil, 0
	for k, v in dist do
		if k ~= top and v > bestp then
			best, bestp = k, v
		end
	end
	return best, bestp
end

-- The moods to sing: the top one, plus a follow-up when the feeling is mixed
-- or a non-asking mood still wants an answer.
function M.syllables(r: Reading): { string }
	local alt, altp = second(r.moods, r.mood)
	if r.asks >= 0.5 and not ASKING[r.mood] then
		return { r.mood, "curious" }
	elseif alt and altp >= M.MIXED then
		return { r.mood, alt }
	end
	return { r.mood }
end

-- One syllable in a voice; the mood contour sets the pitch, the voice the timbre.
local function syllable(voice: string, f0: number, f1: number, d: number, open: number, rand: () -> number): synth.Note
	if voice == "blip" then
		return {
			t = 0, d = d * 0.8, f0 = f0, f1 = f1, wave = "square", amp = 0.42,
			attack = 0.002, curve = 1.8, cutoff0 = f0 * 6 * open, cutoff1 = f1 * 2.5 * open,
		}
	elseif voice == "bubble" then
		return { t = 0, d = d, f0 = f0 * 1.12, f1 = f1 * 0.9, wave = "sine", amp = 0.9, attack = 0.006, curve = 1.1 }
	elseif voice == "robot" then
		return {
			t = 0, d = d, f0 = f0, f1 = f1, wave = "saw", amp = 0.5, attack = 0.004, curve = 0.9,
			ring_hz = 52 + 30 * rand(), cutoff0 = f0 * 5 * open, cutoff1 = f1 * 1.6 * open,
		}
	elseif voice == "chatter" then
		return {
			t = 0, d = d, f0 = f0, f1 = f1, wave = "tri", amp = 0.8, attack = 0.004, curve = 1.2,
			trill = 1.12 + 0.06 * rand(), trill_hz = 22 + 8 * rand(),
		}
	elseif voice == "whisper" then
		return { t = 0, d = d * 1.1, f0 = f0 * 2, f1 = f1 * 2, wave = "noise", amp = 0.9, attack = 0.015, curve = 1.4 }
	end
	-- chirp: a bird-like FM tweet with a little extra lift
	return {
		t = 0, d = d, f0 = f0, f1 = f1 * 1.08, wave = "fm", amp = 0.85,
		attack = 0.004, curve = 1.3, fm_ratio = 2, fm_index = 1.1 * open,
	}
end

-- Notes, effects and a seed for synth.render.
function M.compose(r: Reading, text: string?): ({ synth.Note }, synth.Fx, number)
	local source = text or ""
	local seed = hash(source .. r.mood .. r.voice)
	local rand = rng(seed)
	local words = M.phrase(source)
	local key = table.concat(words, " ")
	local longest = ""
	for _, w in words do
		if #w > #longest then
			longest = w
		end
	end

	local base = 220 * 2 ^ (r.pitch * 1.6 + OFFSETS[hash(key) % #OFFSETS + 1] / 12) -- ~220..800 Hz
	local open = VOWEL[string.match(longest, "[aeiouy]") or "a"] or 1
	local tension = (r.moods.worried or 0) + 0.6 * (r.moods.sheepish or 0)
	local joy = (r.moods.proud or 0) + (r.moods.excited or 0)
	local wobble = math.clamp(1 - r.confidence, 0, 1)
	local amp = 0.6 + 0.4 * r.energy
	local d = lerp(0.3, 0.15, r.rate)

	local alt, altp = second(r.voices, r.voice)
	local moods = M.syllables(r)
	local notes: { synth.Note } = {}
	local t = 0
	for i, mood in moods do
		local c = CONTOUR[mood] or CONTOUR.calm
		local s0, s1 = c[1], c[2]
		local last = i == #moods
		if last and r.asks >= 0.5 then
			-- A question always ends up high.
			s1 = math.max(s1, 0) + 5
		end
		-- A two-syllable sound totals about 1.5x one syllable.
		local len = d * c[4] * (if #moods == 1 then 1 else (if last then 0.85 else 0.6))
		local voice = if i > 1 and alt and altp >= 0.2 then alt else r.voice
		local note = syllable(voice, base * 2 ^ (s0 / 12), base * 2 ^ (s1 / 12), len, open, rand)
		note.t = t
		note.bend = c[3]
		note.amp *= amp
		note.vib = wobble * 0.5 + tension * 0.3
		note.vib_hz = 5 + r.energy * 4
		table.insert(notes, note)
		t += note.d + 0.03
	end

	if joy >= 0.3 then
		-- A sparkle layered over the start when it went well.
		local sparkle: synth.Note = {
			t = 0.02, d = math.min(0.2, d), f0 = base * 3, f1 = base * 3.4, wave = "fm", amp = 0.28 * amp,
			attack = 0.003, curve = 2.2, fm_ratio = 3.5, fm_index = 1.5,
		}
		table.insert(notes, sparkle)
	end

	return notes, { echo = lerp(0.3, 0.18, r.energy) }, seed
end

return M
