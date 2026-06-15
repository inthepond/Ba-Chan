<div align="center">

<img src="docs/banner.gif" alt="Ba-Chan — an animated procedural face that blinks, breathes, and watches" width="100%">

# Ba-Chan

**A tiny on-screen companion that lives on your Mac and iPhone — fully on-device.**

A cute animated face with hearing, a voice, an on-device brain, long-term memory,
and eyes that can see your camera or your screen. No servos, no cloud, no API keys.

</div>

---

Ba-Chan is a native SwiftUI app for **macOS and iOS**, inspired by the open-source
M5Stack **[Stackchan](https://github.com/stack-chan/stack-chan)** desktop robot and
reimplemented purely in software. On the Mac it lives in the **menu bar** as a little
live face that blinks at you while you work; on iPhone it fills the screen. Everything —
the brain, the memory, the speech, the vision — runs **on your own device** by default.

The face is drawn procedurally from a handful of numbers (a SwiftUI `Canvas`), so it
blinks, breathes, wanders its gaze, dozes off, and reacts to your touch without a single
image asset. Over days and weeks its *resting* look even drifts a little — Ba-Chan slowly
becomes its own.

## What it does

- **An expressive procedural face** — autonomous blinking, breathing, and wandering gaze;
  the classic M5Avatar mood set (neutral / happy / sleepy / doubt / angry / sad) plus a
  few more, driven by `[mood]` tags the model emits. Poke its eyes and it gets annoyed;
  pat its head and it blushes. Idle long enough and it reads a book, makes tea, hums, or
  falls asleep.
- **A full voice loop** — microphone → on-device speech-to-text → brain → text-to-speech,
  with **amplitude-driven lip-sync** (the voice is rendered to PCM and the mouth tracks
  the real loudness in real time). Off by default; typing always works.
- **An on-device brain** with several tiers and a graceful fallback:
  - **macOS** — talks to a local **[Ollama](https://ollama.com)** server (`gemma3` by
    default); pull a bigger tag and the brain upgrades itself.
  - **iOS** — **Gemma 3n** running on-device via **[MLX](https://github.com/ml-explore/mlx-swift-examples)**,
    or Apple's **FoundationModels** on iOS 26+.
  - A built-in rule-based **ScriptedBrain** so the whole loop works even with no model
    (and in the Simulator).
  - **Optional cloud brains** (opt-in, breaks the no-keys default) — Claude, OpenAI,
    Gemini, or OpenRouter. Keys live only in the **Keychain**.
- **Long-term memory** — a dependency-free, on-device memory store (Apple `NLEmbedding`
  + cosine similarity + JSON), with mem0-style extract→consolidate and a nightly LLM
  distillation pass. It remembers what matters and gently lets the rest fade. A separate
  time-aware **conversation journal** lets it actually answer "what did we talk about
  yesterday?"
- **Eyes** — point the camera and ask "what do you see"; Ba-Chan uses Apple **Vision**
  (objects, scene, text, faces) and, on a multimodal brain, really looks at the frame.
  On macOS it can also glance at **your screen** when you ask.
- **A presence on your Mac** — Ba-Chan speaks first. It notices the app you're in and how
  long you've been heads-down, says good morning, welcomes you back after a break, and
  nudges you to stretch — delivered as a notification when its face is tucked away in the
  menu bar. Its eyes follow your mouse pointer.
- **Strictly monochrome** — pure black-and-white, inverting cleanly with the system theme.

Everything is private by default: speech, vision, memory, and (on the local brains)
the language model itself never leave your device.

## Build & run

Requires Xcode 26+. Open the project:

```sh
open BaChan.xcodeproj
```

### macOS (the menu-bar companion)

The default macOS brain is a local Ollama server. Install the Ollama **app** and pull a
model first:

```sh
brew install --cask ollama-app
ollama pull gemma3:4b        # or gemma3:12b on a 24 GB+ Mac
```

Then pick the **My Mac** destination in Xcode and Run — Ba-Chan's face appears in the
menu bar. Left-click it for the full face panel; right-click for Settings and Quit.

> The Homebrew *formula* (`brew install ollama`) ships without the inference backend —
> use the **cask** (`ollama-app`) above. Without Ollama running, Ba-Chan falls back to its
> built-in scripted replies.

### iOS

Pick an iPhone (or the Simulator) and Run.

- On a **device**, turn on **Speech** and just talk; turn on **Look** to use the camera.
  The on-device Gemma model is a one-time confirmed download (kept on the device).
- In the **Simulator** there's no camera/mic and MLX can't run, so use the type-to-talk
  field — you still get the brain (scripted), the voice, the lip-sync, and the reactive
  face.

Deployment target is iOS 18; the MLX and FoundationModels brains are gated to the SDKs
that provide them and compiled in only when available.

## How it's put together

```
BaChan/
  BaChanApp.swift     App entry — macOS menu-bar (NSStatusItem) + iOS WindowGroup
  ContentView.swift   The face, toggles, transcript, and input bar
  Conductor.swift     @MainActor state machine: idle → listening → thinking → speaking
  Face/               Procedural Canvas renderer, expressions, genome/appearance evolution
  Audio/              On-device STT + TTS with real-time lip-sync
  Brain/              The Brain protocol + every brain (Ollama, Gemma/MLX, Apple FM,
                      Scripted, and the optional cloud brains) + persona & output guards
  Memory/             On-device long-term memory, distillation, conversation journal
  Vision/             Camera + Apple Vision sight, and macOS screen sight
  Presence/           macOS work-rhythm awareness + proactive moments
  Motion/             Device motion (iOS) and mouse-pointer tracking (macOS)
```

The brain is a one-protocol seam — `protocol Brain { reply(to:context:) }` — so adding a
model is a single new file handed to the `Conductor`.

## Credits

Inspired by the **[Stackchan](https://github.com/stack-chan/stack-chan)** open-source
desktop robot by Shinya Ishikawa and the M5Stack community. Ba-Chan reimplements its three
charming software ideas — a procedural face, amplitude-driven lip-sync, and a small
conversational loop — as a pure-software companion, and grows them into something that
remembers and evolves.

## License

[MIT](LICENSE).
