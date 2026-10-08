# Changelog

## 0.1.0

First release.

- Watches agent blocks and speaks when one finishes a turn or stops to wait for input. It stays quiet for short turns in the focused pane, and with several windows open it speaks each turn once.
- Jev reads each turn with six typed questions: mood, voice, pitch, pace, energy, and whether you are asked something. All six go in one TypeSafe request, with one retry when TypeSafe is overloaded. Without Jev, a local reading uses the agent state and closing punctuation.
- One soft syllable per turn, or two when feelings are mixed. Pitch shape comes from the mood and timbre from the voice. Mixed moods, unsure readings and questions change the sound too.
- Pure-Luau synthesizer (24 kHz mono WAV, FM, polyBLEP square/saw, ring modulation, filtered noise, short echo, master low-pass), played with `afplay` or `paplay`.
- Palette commands: mute, say the focused agent's turn, replay, explain the last chirp, louder, softer.
