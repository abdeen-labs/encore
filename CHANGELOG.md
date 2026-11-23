# Changelog

All notable changes to Encore are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

At release time, `scripts/publish-release.sh` puts the section for the version being shipped in the appcast, and
Encore's update window shows it, so keep entries user-facing and write them for someone deciding whether to install
the update.

## [Unreleased]

<!-- Add entries here, under [Unreleased]. At release, leave this heading and comment in place and insert the new
     "## [x.y] - YYYY-MM-DD" heading just below, so the entries fall under it; then repoint the [Unreleased] link
     and add a link for the new version at the bottom. -->

## [1.3] - 2026-11-22

Scripts and AI agents on your Mac can now use Encore, through a local API and an MCP server you turn on in Settings.

### Added

- A local API, off until you turn it on in Settings. While Encore is open, scripts and AI agents on your Mac can
  make speech, perform scripts, transcribe and change voices with your models and voices. Add Encore to Claude Code
  or another MCP client as an MCP server, or point any app built for OpenAI's speech and transcription API at it.
  Only apps on this Mac can connect, and web pages can't reach it.

### Changed

- A sound tag like `[laugh]` is now flagged as a warning when the chosen model has no sound tags, since the model
  may read it out loud instead.

## [1.2] - 2026-11-22

A whole new look: cream, cocoa and tangerine, set in the round, friendly Allo typeface, with an app icon you can pick.

### Added

- An App icon picker in Settings: keep the bubble, or put the candy-bar icon in your Dock. It stays there after
  Encore quits.

### Changed

- A whole new look: Encore is now cream and cocoa with a tangerine accent, set in the rounded Allo typeface.
  Buttons are soft capsules you can press, cards float, empty screens have a sticker instead of a spotlight, and
  there's a new speech-bubble app icon.
- Friendlier words on the screens' taglines and empty states.

## [1.1] - 2026-11-22

VoxCPM2 keeps a cloned voice's accent, and each model now runs where it runs best.

### Fixed

- VoxCPM2 keeps a cloned voice's accent. With a transcript on the voice, it now clones from the clip and its words
  together (in the Python helper), instead of from the sound of the clip alone, where a British voice could come
  back with an American accent.
- Chatterbox Multilingual with the language on Automatic no longer reads everything as English: it speaks the
  script's language, or else the voice's.
- Whisper keeps retrying passages that come out stuck or repeating after you change Temperature.
- Long recordings transcribed by Parakeet in the Python helper overlap their pieces by 15 seconds, so words at the
  seams line up.
- A shortened reference clip keeps its transcript when the voice has no language set.
- OmniVoice in the Python helper makes audio with Length left at automatic, instead of none.

### Changed

- Automatic runs each model where it runs best: VoxCPM2 and Whisper in the Python helper, the rest natively.
  A model's page says where and why. A runtime you pick for a model still wins.
- When a model can't run where it runs best (the Python helper isn't set up), Studio, Conversations and
  Transcribe say so, and what that costs.
- Studio takes show which model made them, next to the voice and length.

## [1.0] - 2026-11-21

The first release of Encore: local voice AI for Apple Silicon Macs. Everything runs on your Mac, with no account and no cloud.

### Added

- Turn text into speech in the Studio, with tags for pauses, voice changes and sounds like `[laugh]`, and a pronunciation list for names and jargon.
- Clone a voice from 5 to 15 seconds of any recording, or design a new one by describing it and auditioning several at once.
- Perform a whole script or screenplay (.txt, .md, .fountain, .pdf) with a voice for each speaker. Change one line and only that line is generated again.
- Re-voice a recording in one of your voices, keeping its words, timing and delivery.
- Transcribe audio and video with sentence or word timings, and export plain text, SRT, WebVTT or JSON.
- Keep cloned, designed and imported voices in one library, and share them as .encorevoice files.
- Find every take with the script and settings it was made with, and export it as WAV, M4A or MP3.
- Choose from sixteen speech, transcription and voice-changer models, downloaded as you need them.
- Encore checks for updates and installs them for you.

[Unreleased]: https://github.com/abdeen-labs/encore/compare/v1.3...HEAD
[1.3]: https://github.com/abdeen-labs/encore/compare/v1.2...v1.3
[1.2]: https://github.com/abdeen-labs/encore/compare/v1.1...v1.2
[1.1]: https://github.com/abdeen-labs/encore/compare/v1.0...v1.1
[1.0]: https://github.com/abdeen-labs/encore/tree/v1.0
