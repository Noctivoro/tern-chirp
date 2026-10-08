--!strict
-- Checks for lib/. Run with `luau test/run.luau` from the plugin root.

local director = require("../lib/director")
local synth = require("../lib/synth")
local voice = require("../lib/voice")

local failures, passes = 0, 0

local function check(cond: boolean, msg: string)
	if cond then
		passes += 1
	else
		failures += 1
		print("FAIL: " .. msg)
	end
end

-- A real /v1/systemone answer shape (2026-10-07), trimmed to our questions.
local function response(): any
	return {
		model = "jev-1.13.0",
		answers = {
			mood = {
				type = "choice", choice = "worried", confidence = 0.7,
				probabilities = { curious = 0.05, eager = 0.0, proud = 0.01, excited = 0, calm = 0.19, worried = 0.75, sheepish = 0 },
			},
			voice = {
				type = "choice", choice = "robot", confidence = 0.6,
				probabilities = { chirp = 0.1, blip = 0.25, bubble = 0, robot = 0.6, chatter = 0.05, whisper = 0 },
			},
			pitch = { type = "score", score = 1.93, probabilities = { ["0"] = 0.04, ["1"] = 0.06, ["2"] = 0.84, ["3"] = 0.05, ["4"] = 0.01 } },
			rate = { type = "score", probabilities = { ["0"] = 0, ["1"] = 0, ["2"] = 0, ["3"] = 0, ["4"] = 1 } },
			energy = { type = "score", score = 0, probabilities = { ["0"] = 1, ["1"] = 0, ["2"] = 0, ["3"] = 0, ["4"] = 0 } },
			asks = { type = "noul", noul = 0.98 },
		},
	}
end

do
	local r = director.parse(response())
	check(r ~= nil, "parse accepts a full answer")
	if r then
		check(r.mood == "worried" and r.voice == "robot", "parse picks the top mood and voice")
		check(math.abs(r.pitch - 1.93 / 4) < 1e-9, "parse maps the expected score to 0..1")
		check(r.rate == 1, "parse computes the expectation when score is absent")
		check(r.energy == 0 and r.asks == 0.98 and r.confidence == 0.7, "parse keeps energy, asks, confidence")
		check(r.source == "jev" and r.model == "jev-1.13.0", "parse records the source and model")
	end

	local missing = response()
	missing.answers.asks = nil
	check(director.parse(missing) == nil, "parse rejects a missing answer")
	local partial = response()
	partial.answers.voice.probabilities.whisper = nil
	check(director.parse(partial) == nil, "parse rejects a distribution missing a key")
	check(director.parse("oops") == nil, "parse rejects a non-table")
end

do
	local req = director.request({ event = "idle", text = string.rep("é", 2000) .. "Ship it?" })
	local msg = req.state.message :: string
	check(utf8.len(msg) ~= nil, "excerpt cuts on character boundaries")
	check((utf8.len(msg) :: number) < 900, "excerpt is bounded")
	check(string.sub(msg, -8) == "Ship it?", "excerpt keeps the end, where questions sit")
	local q = req.questions
	check(q.pitch.type == "score" and #q.pitch.criteria == 5, "score questions have five levels")
	local bad = director.request({ event = "idle", text = "ok \255\254 done" })
	check(utf8.len(bad.state.message) ~= nil, "excerpt drops invalid UTF-8")
end

do
	local w = voice.phrase("Built it. Tests pass (12/12). Should I push to `main` now? Thanks.")
	check(table.concat(w, " ") == "should i push to now", "phrase is the last question, code removed")
	local d = voice.phrase("Deployed the preview. Everything is green.")
	check(table.concat(d, " ") == "deployed the preview", "phrase falls back to the first sentence")
	check(#voice.phrase("") == 0, "empty text has no phrase")
end

do
	local asks = director.fallback({ event = "idle", text = "Want me to merge?  \n" })
	check(asks.mood == "curious" and asks.asks == 1 and asks.source == "local", "fallback hears a trailing question")
	local done = director.fallback({ event = "idle", text = "Done." })
	check(done.mood == "calm" and done.asks == 0, "fallback is calm for a plain finish")
	local blocked = director.fallback({ event = "waiting_input", text = "" })
	check(blocked.asks == 1, "fallback treats waiting_input as a question")
end

do
	local r = director.parse(response()) :: voice.Reading
	local text = "Two redirects still 404. Push the fix to main, or open a PR first?"
	local a, fxa, seeda = voice.compose(r, text)
	local b, _, seedb = voice.compose(r, text)
	check(seeda == seedb and #a == #b, "the same message composes the same notes")
	local same = true
	for i = 1, #a do
		if a[i].f0 ~= b[i].f0 or a[i].t ~= b[i].t then
			same = false
		end
	end
	check(same, "the same message composes identical pitches and timing")
	local function span(notes: { any }): number
		local finish = 0
		for _, n in notes do
			finish = math.max(finish, n.t + n.d)
		end
		return finish
	end

	-- Worried, but asking: the trouble, then a rising question.
	check(table.concat(voice.syllables(r), ",") == "worried,curious", "a worried question is two syllables")
	check(#a == 2 and a[2].f1 > a[2].f0, "a question ends rising")
	check(a[1].f1 < a[1].f0, "worry droops first")

	local plain = director.fallback({ event = "idle", text = "Updated the README." })
	check(#voice.syllables(plain) == 1, "a clear, plain finish is one syllable")
	local one = voice.compose(plain, "Updated the README.")
	check(#one == 1 and span(one) >= 0.12 and span(one) <= 0.4, "one syllable lasts a fraction of a second")

	local curious = director.fallback({ event = "idle", text = "Merge it?" })
	check(#voice.syllables(curious) == 1, "a curious question needs no second syllable")

	local mixed = director.fallback({ event = "idle", text = "Done, mostly." })
	mixed.moods = { curious = 0, eager = 0, proud = 0.6, excited = 0, calm = 0.05, worried = 0, sheepish = 0.35 }
	mixed.mood = "proud"
	check(table.concat(voice.syllables(mixed), ",") == "proud,sheepish", "mixed feelings are two syllables")
	local two = voice.compose(mixed, "Done, mostly.")
	local voiced = {}
	for _, n in two do
		if n.t ~= 0.02 then
			table.insert(voiced, n)
		end
	end
	check(#voiced == 2 and span(voiced) <= 2 * span(one), "two syllables stay well under twice one")
	check(two[#two].wave == "fm" and two[#two].f0 > two[1].f0, "a win carries a sparkle above it")

	local wav, secs = synth.render(a, fxa, seeda)
	check(string.sub(wav, 1, 4) == "RIFF" and string.sub(wav, 9, 12) == "WAVE", "render writes a WAV header")
	check(#wav == 44 + math.floor(secs * synth.RATE + 0.5) * 2, "WAV length matches the rendered seconds")
	check(secs < 1.0, "even two syllables with echo end within a second")
	local peak = 0
	for i = 45, #wav - 1, 2 do
		local v = string.unpack("<i2", wav, i) :: number
		peak = math.max(peak, math.abs(v))
	end
	local target = synth.PEAK * 32767
	check(peak > target * 0.95 and peak < target * 1.01, "render peaks at the soft level, never full scale")
end

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then
	error("test failures")
end
