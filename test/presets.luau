--!strict
-- Renders one WAV per preset for listening; prints `name<TAB>seconds<TAB>ms<TAB>hex`
-- lines that bin/audition.mjs writes to files. Luau's CLI has no file I/O.

local synth = require("../lib/synth")
local voice = require("../lib/voice")

type Preset = {
	name: string, mood: string, also: string?, voice: string, alt: string?,
	pitch: number, rate: number, energy: number, asks: number, confidence: number, text: string,
}

local PRESETS: { Preset } = {
	-- One syllable: a clear feeling.
	{ name = "1-curious", mood = "curious", voice = "chirp", pitch = 0.6, rate = 0.55, energy = 0.5, asks = 0.97, confidence = 0.85,
		text = "Should I push the redirect fix to main, or open a PR first?" },
	{ name = "1-eager", mood = "eager", voice = "blip", pitch = 0.55, rate = 0.75, energy = 0.7, asks = 0.95, confidence = 0.8,
		text = "Ready to deploy when you say go?" },
	{ name = "1-proud", mood = "proud", voice = "bubble", pitch = 0.6, rate = 0.5, energy = 0.55, asks = 0.05, confidence = 0.85,
		text = "Built the city pages and all 28 checks pass." },
	{ name = "1-excited", mood = "excited", voice = "chirp", pitch = 0.85, rate = 0.9, energy = 0.95, asks = 0.1, confidence = 0.9,
		text = "Launch is live, every redirect returns 301 and the forms deliver." },
	{ name = "1-calm", mood = "calm", voice = "blip", pitch = 0.45, rate = 0.4, energy = 0.3, asks = 0.1, confidence = 0.9,
		text = "Updated the README with the new commands." },
	{ name = "1-worried", mood = "worried", voice = "robot", pitch = 0.3, rate = 0.45, energy = 0.5, asks = 0.2, confidence = 0.8,
		text = "The deploy failed: Wrangler returned 403 on the asset upload." },
	{ name = "1-sheepish", mood = "sheepish", voice = "whisper", pitch = 0.35, rate = 0.3, energy = 0.25, asks = 0.2, confidence = 0.8,
		text = "Sorry, I could not reproduce the bug and reverted my change." },
	-- Two syllables: mixed feelings, or trouble that needs your answer.
	{ name = "2-worried-asks", mood = "worried", voice = "robot", alt = "chirp", pitch = 0.35, rate = 0.5, energy = 0.55, asks = 0.95, confidence = 0.6,
		text = "Two redirects still 404. Push the fix to main, or open a PR first?" },
	{ name = "2-proud-sheepish", mood = "proud", also = "sheepish", voice = "bubble", alt = "whisper", pitch = 0.55, rate = 0.5, energy = 0.5, asks = 0.1, confidence = 0.55,
		text = "Most pages shipped, but I skipped the two I could not verify." },
	{ name = "2-excited-worried", mood = "excited", also = "worried", voice = "chirp", alt = "robot", pitch = 0.7, rate = 0.7, energy = 0.8, asks = 0.2, confidence = 0.5,
		text = "Rankings jumped, but the sitemap check is now failing." },
	{ name = "2-calm-chatter-asks", mood = "calm", voice = "chatter", pitch = 0.5, rate = 0.8, energy = 0.6, asks = 0.7, confidence = 0.6,
		text = "Here is the audit: twelve thin pages and four broken links. Want the fix list?" },
}

for _, pr in PRESETS do
	local moods = {}
	for _, m in voice.MOODS do
		moods[m] = if m == pr.mood then pr.confidence elseif m == pr.also then 1 - pr.confidence else 0
	end
	if not pr.also then
		for _, m in voice.MOODS do
			if m ~= pr.mood then
				moods[m] = (1 - pr.confidence) / (#voice.MOODS - 1)
			end
		end
	end
	local voices = {}
	for _, v in voice.VOICES do
		voices[v] = if v == pr.voice then 0.6 elseif v == pr.alt then 0.3 else 0.02
	end
	local r: voice.Reading = {
		mood = pr.mood, moods = moods, voice = pr.voice, voices = voices,
		pitch = pr.pitch, rate = pr.rate, energy = pr.energy, asks = pr.asks,
		confidence = pr.confidence, source = "local", model = nil,
	}
	local started = os.clock()
	local notes, fx, seed = voice.compose(r, pr.text)
	local wav, secs = synth.render(notes, fx, seed)
	local ms = (os.clock() - started) * 1000
	local hex = string.gsub(wav, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end)
	print(string.format("%s\t%.2f\t%.1f\t%s", pr.name, secs, ms, hex))
end
