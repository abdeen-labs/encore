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

[Unreleased]: https://github.com/abdeen-labs/encore/compare/v1.0...HEAD
[1.0]: https://github.com/abdeen-labs/encore/tree/v1.0
