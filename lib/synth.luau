--!strict
--!native
-- Renders notes to a 16-bit mono WAV. Pure Luau so the window half can make
-- a sound without helpers; `afplay` (or `paplay`) only plays the file.

local M = {}

M.RATE = 24000
-- Loudest sample after normalising: well under full scale, so a chirp is
-- a nudge, not an alarm.
M.PEAK = 0.5
-- Master low-pass that rounds off the edges of every voice.
M.SOFTEN_HZ = 2500

export type Wave = "sine" | "square" | "saw" | "tri" | "fm" | "noise"

export type Note = {
	-- Start and length in seconds.
	t: number,
	d: number,
	-- Pitch glides from f0 to f1 (Hz), fast at first.
	f0: number,
	f1: number,
	wave: Wave,
	amp: number,
	attack: number?,
	-- Decay exponent after the attack: 1 linear, higher drops sooner.
	curve: number?,
	-- Arc over the note in semitones: positive rises then returns, negative dips.
	bend: number?,
	-- Vibrato depth in semitones and rate.
	vib: number?,
	vib_hz: number?,
	-- Alternates pitch by this ratio at trill_hz (a robot warble).
	trill: number?,
	trill_hz: number?,
	-- FM carrier/modulator ratio and index, which decays with the envelope.
	fm_ratio: number?,
	fm_index: number?,
	-- Ring modulation frequency (metallic voice).
	ring_hz: number?,
	-- One-pole low-pass sweep in Hz; nil leaves the tone open.
	cutoff0: number?,
	cutoff1: number?,
}

export type Fx = {
	-- Feedback of the echo, 0..0.6.
	echo: number,
}

local TAU = 2 * math.pi

local function blep(t: number, dt: number): number
	if t < dt then
		t /= dt
		return t + t - t * t - 1
	elseif t > 1 - dt then
		t = (t - 1) / dt
		return t * t + t + t + 1
	end
	return 0
end

local function render_note(mix: { number }, n: Note, seed: number)
	local rate = M.RATE
	local first = math.floor(n.t * rate) + 1
	local count = math.max(1, math.floor(n.d * rate))
	local last = math.min(#mix, first + count - 1)
	-- At least 12 ms so no onset clicks.
	local attack = math.max(0.012, n.attack or 0.012)
	local curve = n.curve or 1.5
	local vib = n.vib or 0
	local vib_hz = n.vib_hz or 6
	local trill = n.trill or 1
	local trill_hz = n.trill_hz or 20
	local fm_ratio = n.fm_ratio or 2
	local fm_index = n.fm_index or 0
	local ring_hz = n.ring_hz or 0
	local bend = n.bend or 0
	local c0 = n.cutoff0
	local c1 = n.cutoff1 or c0
	local ratio = n.f1 / n.f0
	local phase, mphase, lp, bp_lo, bp_hi = 0, 0, 0, 0, 0
	local noise = bit32.bor(seed, 1)
	local wave = n.wave
	local ramp = 0.003 * rate

	for i = first, last do
		local k = i - first
		local secs = k / rate
		local p = k / count
		-- Pitch: fast-start glide, arc, vibrato and trill.
		local g = 1 - (1 - p) * (1 - p)
		local f = n.f0 * ratio ^ g
		if bend ~= 0 then
			f *= 2 ^ (bend * math.sin(math.pi * p) / 12)
		end
		if vib > 0 then
			f *= 2 ^ (vib * math.sin(TAU * vib_hz * secs) / 12)
		end
		if trill ~= 1 and math.floor(secs * trill_hz) % 2 == 1 then
			f *= trill
		end
		local dt = f / rate

		-- Envelope: linear attack, power-curve decay, short end ramp.
		local env
		if secs < attack then
			env = secs / attack
		else
			env = (1 - (secs - attack) / math.max(1e-6, n.d - attack)) ^ curve
		end
		local tail = last - i
		if tail < ramp then
			env *= tail / ramp
		end

		local s
		if wave == "sine" then
			s = math.sin(TAU * phase)
		elseif wave == "fm" then
			s = math.sin(TAU * phase + fm_index * env * math.sin(TAU * mphase))
			mphase = (mphase + dt * fm_ratio) % 1
		elseif wave == "saw" then
			s = 2 * phase - 1 - blep(phase, dt)
		elseif wave == "square" then
			s = (if phase < 0.5 then 1 else -1) + blep(phase, dt) - blep((phase + 0.5) % 1, dt)
		elseif wave == "tri" then
			s = 1 - 4 * math.abs(phase - 0.5)
		else
			-- Noise band around f with a quiet tone under it: a breathy whisper.
			noise = bit32.bxor(noise, bit32.lshift(noise, 13))
			noise = bit32.bxor(noise, bit32.rshift(noise, 17))
			noise = bit32.bxor(noise, bit32.lshift(noise, 5))
			local white = noise / 2147483648 - 1
			local hi = math.min(1, TAU * f * 1.5 / rate)
			local lo = math.min(1, TAU * f * 0.6 / rate)
			bp_hi += hi * (white - bp_hi)
			bp_lo += lo * (white - bp_lo)
			s = (bp_hi - bp_lo) * 2.2 + 0.3 * math.sin(TAU * phase)
		end
		phase = (phase + dt) % 1

		if ring_hz > 0 then
			s *= 0.55 + 0.45 * math.sin(TAU * ring_hz * secs)
		end
		if c0 then
			local cutoff = c0 + ((c1 :: number) - c0) * p
			local a = math.min(1, TAU * cutoff / rate)
			lp += a * (s - lp)
			s = lp
		end
		mix[i] += s * env * n.amp
	end
end

local function wav(mix: { number }, n: number, peak: number): string
	local rate = M.RATE
	local b = buffer.create(44 + n * 2)
	buffer.writestring(b, 0, "RIFF")
	buffer.writeu32(b, 4, 36 + n * 2)
	buffer.writestring(b, 8, "WAVEfmt ")
	buffer.writeu32(b, 16, 16)
	buffer.writeu16(b, 20, 1)
	buffer.writeu16(b, 22, 1)
	buffer.writeu32(b, 24, rate)
	buffer.writeu32(b, 28, rate * 2)
	buffer.writeu16(b, 32, 2)
	buffer.writeu16(b, 34, 16)
	buffer.writestring(b, 36, "data")
	buffer.writeu32(b, 40, n * 2)
	local scale = if peak > 0 then M.PEAK / peak else 0
	for i = 1, n do
		local v = math.clamp(mix[i] * scale, -1, 1)
		buffer.writei16(b, 44 + (i - 1) * 2, math.floor(v * 32767 + 0.5))
	end
	return buffer.tostring(b)
end

-- Renders `notes` with an echo tail; returns WAV bytes and their length in seconds.
function M.render(notes: { Note }, fx: Fx, seed: number?): (string, number)
	local rate = M.RATE
	local finish = 0
	for _, n in notes do
		finish = math.max(finish, n.t + n.d)
	end
	local tail = 0.22
	local count = math.floor((finish + tail) * rate) + 1
	local mix = table.create(count, 0)
	for i, n in notes do
		render_note(mix, n, (seed or 1) + i * 7919)
	end

	-- Two short echo taps with feedback: a small room around a small robot.
	local fb = math.clamp(fx.echo, 0, 0.6)
	local d1 = math.floor(0.07 * rate)
	local d2 = math.floor(0.13 * rate)
	for i = d1 + 1, count do
		local v = mix[i] + mix[i - d1] * fb
		if i > d2 then
			v += mix[i - d2] * fb * 0.5
		end
		mix[i] = v
	end

	-- Two one-pole low-passes (12 dB/octave): softer highs, same shapes.
	local a = math.min(1, TAU * M.SOFTEN_HZ / rate)
	local s1, s2 = 0, 0
	for i = 1, count do
		s1 += a * (mix[i] - s1)
		s2 += a * (s1 - s2)
		mix[i] = s2
	end

	-- Soft clip, then normalise to the loudest sample.
	local peak = 0
	for i = 1, count do
		local v = mix[i]
		v = v / (1 + math.abs(v) * 0.6)
		mix[i] = v
		peak = math.max(peak, math.abs(v))
	end
	local fade = math.floor(0.05 * rate)
	for i = count - fade + 1, count do
		mix[i] *= (count - i) / fade
	end
	return wav(mix, count, peak), count / rate
end

return M
