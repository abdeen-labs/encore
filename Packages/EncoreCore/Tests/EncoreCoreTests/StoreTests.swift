import Foundation
import Observation
import Testing
@testable import EncoreCore

/// Polls until `condition` holds (or fails after `timeout`).
@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { Issue.record("Timed out waiting", sourceLocation: sourceLocation); return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

final class ObservationFlag: @unchecked Sendable { var fired = false }

/// True if reading `read` and then running `change` triggers an observation callback.
@MainActor
func observes<T>(_ read: () -> T, after change: () throws -> Void) rethrows -> Bool {
    let flag = ObservationFlag()
    withObservationTracking { _ = read() } onChange: { flag.fired = true }
    try change()
    return flag.fired
}

// MARK: - Voice library

@MainActor @Suite struct StoreVoiceLibraryTests {
    let dir: TempDir
    let clip: URL

    init() throws {
        dir = try TempDir()
        clip = dir.url.appendingPathComponent("clip.wav")
        try Data("RIFF fake wav data".utf8).write(to: clip)
    }

    func library(_ name: String = "Voices") -> VoiceLibrary {
        VoiceLibrary(directory: dir.url.appendingPathComponent(name), deletesToTrash: false)
    }

    @Test func createResolveAndPersist() async throws {
        let lib = library()
        let v = try await lib.add(Voice(name: "  Ava ", tags: ["warm", "Warm", " narrator "], origin: .cloned,
                                        transcript: "Hello there.", duration: 4), referenceAudio: clip)
        #expect(v.name == "Ava" && v.tags == ["warm", "narrator"])
        #expect(FileManager.default.fileExists(atPath: clip.path))
        #expect(lib.voices.map(\.id) == [v.id])
        let ref = try #require(lib.referenceAudioURL(for: v.id))
        #expect(ref.lastPathComponent == "reference.wav")
        #expect(try Data(contentsOf: ref) == Data(contentsOf: clip))

        // Resolution works off the main actor.
        let engine = try await Task.detached { try lib.engineVoice(for: .library(v.id)) }.value
        #expect(engine == EngineVoice(referenceAudio: ref, referenceText: "Hello there."))
        #expect(try lib.engineVoice(for: .preset("af_heart")) == EngineVoice(preset: "af_heart"))
        #expect(try lib.engineVoice(for: .automatic) == nil)
        #expect(throws: StoreError.self) { try lib.engineVoice(for: .library(UUID())) }

        let reopened = library()
        #expect(reopened.voices == lib.voices)
        #expect(reopened.problems.isEmpty)
    }

    @Test func moveConsumesTheSourceClip() async throws {
        let lib = library()
        let tmp = dir.url.appendingPathComponent("temp.m4a")
        try Data("m4a".utf8).write(to: tmp)
        let v = try await lib.add(Voice(name: "Tmp", origin: .designed, transcript: "", duration: 1), referenceAudio: tmp, move: true)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        #expect(lib.referenceAudioURL(for: v.id)?.pathExtension == "m4a")
        #expect(try lib.engineVoice(for: .library(v.id))?.referenceText == nil)
    }

    @Test func editRenameTagsNotesTranscript() async throws {
        let lib = library()
        let v = try await lib.add(Voice(name: "Ava", origin: .cloned, transcript: "a", duration: 1), referenceAudio: clip)
        try lib.rename(v.id, to: "Ava Stone")
        try lib.setTags(["calm", "", "Calm", "deep"], for: v.id)
        try lib.setNotes("Recorded in May", for: v.id)
        try lib.setTranscript("Corrected words.", for: v.id)
        let reopened = library().voice(v.id)
        #expect(reopened?.name == "Ava Stone")
        #expect(reopened?.tags == ["calm", "deep"])
        #expect(reopened?.notes == "Recorded in May")
        #expect(reopened?.transcript == "Corrected words.")
        #expect(throws: StoreError.self) { try lib.rename(UUID(), to: "x") }
    }

    @Test func duplicateAndDelete() async throws {
        let lib = library()
        let v = try await lib.add(Voice(name: "Ava", origin: .cloned, transcript: "a", duration: 1), referenceAudio: clip)
        let copy = try await lib.duplicate(v.id)
        let copy2 = try await lib.duplicate(v.id)
        #expect(copy.id != v.id && copy.name == "Ava copy" && copy2.name == "Ava copy 2")
        #expect(lib.referenceAudioURL(for: copy.id) != lib.referenceAudioURL(for: v.id))
        try lib.delete(v.id)
        #expect(!FileManager.default.fileExists(atPath: lib.folder(for: v.id).path))
        #expect(lib.voices.count == 2)
        #expect(lib.referenceAudioURL(for: copy.id).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(library().voices.count == 2)
    }

    @Test func searchAndTags() async throws {
        let lib = library()
        _ = try await lib.add(Voice(name: "Zoë", tags: ["Warm", "female"], origin: .cloned, transcript: "the quick fox", duration: 1), referenceAudio: clip)
        _ = try await lib.add(Voice(name: "Bram", tags: ["deep"], origin: .designed, transcript: "", designPrompt: "gravelly old man", duration: 1), referenceAudio: clip)
        #expect(lib.allTags == ["deep", "female", "Warm"])
        #expect(lib.search("zoe").map(\.name) == ["Zoë"])
        #expect(lib.search("GRAVEL").map(\.name) == ["Bram"])
        #expect(lib.search("quick zo").map(\.name) == ["Zoë"])
        #expect(lib.search(tags: ["warm"]).map(\.name) == ["Zoë"])
        #expect(lib.search("bram", tags: ["warm"]).isEmpty)
        #expect(lib.search().count == 2)
    }

    @Test func exportImportRoundTripWithoutClobbering() async throws {
        let lib = library()
        let a = try await lib.add(Voice(name: "Ava", tags: ["x"], origin: .cloned, transcript: "one", duration: 2,
                                        consentConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000)), referenceAudio: clip)
        let b = try await lib.add(Voice(name: "Bram", origin: .designed, transcript: "two", designPrompt: "deep", duration: 3),
                                  referenceAudio: clip)
        let file = dir.url.appendingPathComponent("Both.\(VoiceLibrary.fileExtension)")
        try await lib.export([a.id, b.id], to: file)

        // Into a fresh library: same ids and metadata, origin marked imported.
        let other = library("Other")
        let imported = try await other.importVoices(from: file, consentConfirmedAt: Date())
        #expect(Set(imported.map(\.id)) == [a.id, b.id])
        let ia = try #require(other.voice(a.id))
        #expect(ia.name == "Ava" && ia.transcript == "one" && ia.tags == ["x"] && ia.origin == .imported)
        #expect(try Data(contentsOf: other.referenceAudioURL(for: b.id)!) == Data(contentsOf: clip))

        // Into the same library: new ids, originals untouched.
        try lib.rename(a.id, to: "Ava (edited)")
        let again = try await lib.importVoices(from: file, consentConfirmedAt: Date())
        #expect(again.allSatisfy { $0.id != a.id && $0.id != b.id })
        #expect(lib.voice(a.id)?.name == "Ava (edited)")
        #expect(lib.voices.count == 4)
    }

    @Test func importingACloneNeedsTheImportersConsent() async throws {
        let lib = library()
        let exporterDate = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try await lib.add(Voice(name: "Ava", origin: .cloned, transcript: "one", duration: 2,
                                        consentConfirmedAt: exporterDate), referenceAudio: clip)
        let b = try await lib.add(Voice(name: "Bram", origin: .designed, transcript: "two", designPrompt: "deep", duration: 3),
                                  referenceAudio: clip)
        let file = dir.url.appendingPathComponent("Both.\(VoiceLibrary.fileExtension)")
        try await lib.export([a.id, b.id], to: file)

        // Looking inside adds nothing and shows which voices need consent.
        let other = library("Other")
        let peek = try await other.inspectArchive(file)
        #expect(Set(peek.map(\.id)) == [a.id, b.id])
        #expect(peek.filter(\.needsSpeakerConsent).map(\.id) == [a.id])
        #expect(other.voices.isEmpty)

        // Without the importer's consent the whole file is refused and nothing is added.
        do {
            try await other.importVoices(from: file)
            Issue.record("A cloned voice was imported without consent")
        } catch let error as StoreError {
            guard case .consentRequired = error else { Issue.record("Wrong error: \(error)"); return }
        }
        #expect(other.voices.isEmpty)

        // With it, the clone carries the importer's date (now), never the exporter's; the designed voice carries none.
        let now = Date()
        try await other.importVoices(from: file, consentConfirmedAt: now)
        let ia = try #require(other.voice(a.id)), ib = try #require(other.voice(b.id))
        #expect(ia.consentConfirmedAt == now)
        #expect(ia.consentConfirmedAt != exporterDate)
        #expect(ib.consentConfirmedAt == nil)
        // Saved to disk that way, not just returned.
        let reread = library("Other").voice(a.id)?.consentConfirmedAt
        #expect(reread.map { abs($0.timeIntervalSince(now)) < 1 } == true)
        // Imported voices keep their kind for the next import: the designed one still needs no consent, the clone does.
        #expect(!ib.needsSpeakerConsent && ia.needsSpeakerConsent)

        // A file of designed voices only needs no consent.
        let designedOnly = dir.url.appendingPathComponent("Designed.\(VoiceLibrary.fileExtension)")
        try await lib.export([b.id], to: designedOnly)
        let third = library("Third")
        let d = try await third.importVoices(from: designedOnly)
        #expect(d.map(\.name) == ["Bram"])
        #expect(d.first?.consentConfirmedAt == nil)
    }

    @Test func importRejectsJunk() async throws {
        let lib = library()
        let junk = dir.url.appendingPathComponent("junk.encorevoice")
        try Data("not a zip".utf8).write(to: junk)
        await #expect(throws: StoreError.self) { try await lib.importVoices(from: junk, consentConfirmedAt: Date()) }
        // A valid zip that isn't a voice archive.
        let folder = dir.url.appendingPathComponent("zipme")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let zip = dir.url.appendingPathComponent("other.encorevoice")
        try await StoreFiles.run("/usr/bin/ditto", ["-c", "-k", folder.path, zip.path])
        await #expect(throws: StoreError.self) { try await lib.importVoices(from: zip, consentConfirmedAt: Date()) }
        #expect(lib.voices.isEmpty)
    }

    @Test func damagedFolderIsReportedNotFatal() async throws {
        let lib = library()
        _ = try await lib.add(Voice(name: "Ok", origin: .cloned, transcript: "", duration: 1), referenceAudio: clip)
        let bad = lib.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: bad.appendingPathComponent("voice.json"))
        let reopened = library()
        #expect(reopened.voices.count == 1)
        #expect(reopened.problems.count == 1)
    }

    @Test func observationFiresOnChange() async throws {
        let lib = library()
        let v = try await lib.add(Voice(name: "Ava", origin: .cloned, transcript: "", duration: 1), referenceAudio: clip)
        #expect(try observes({ lib.voices }) { try lib.rename(v.id, to: "B") })
        #expect(try observes({ lib.voices }) { try lib.delete(v.id) })
    }
}

// MARK: - Presets

@MainActor @Suite struct StorePresetTests {
    @Test func crudAndListByModel() async throws {
        let dir = try TempDir()
        let store = PresetStore(directory: dir.url)
        #expect(store.presets.isEmpty && store.loadError == nil)
        let warm = Preset(name: "Warm", modelID: "zonos3-mini", parameters: ["speed": .double(0.9)])
        let alpha = Preset(name: "alpha", modelID: "zonos3-mini", parameters: [:])
        let other = Preset(name: "Fast", modelID: "qwen3", parameters: ["temperature": .double(0.7)])
        try store.save(warm); try store.save(alpha); try store.save(other)
        #expect(store.presets(for: "zonos3-mini").map(\.name) == ["alpha", "Warm"])
        try store.rename(warm.id, to: " Warmer ")
        #expect(store.preset(warm.id)?.name == "Warmer")
        try store.delete(alpha.id)
        let reopened = PresetStore(directory: dir.url)
        #expect(reopened.presets.map(\.name) == ["Warmer", "Fast"])
        #expect(reopened.presets[0].parameters == ["speed": .double(0.9)])
        #expect(try observes({ store.presets }) { try store.delete(other.id) })
        let found = try #require(await Task.detached { store.preset(warm.id) }.value)
        #expect(found.name == "Warmer")
    }

    @Test func damagedFileIsKeptAside() throws {
        let dir = try TempDir()
        try Data("[{bad".utf8).write(to: dir.url.appendingPathComponent("presets.json"))
        let store = PresetStore(directory: dir.url)
        #expect(store.loadError != nil && store.presets.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(files.contains { $0.hasPrefix("presets.damaged-") })
    }
}

// MARK: - Pronunciations

@MainActor @Suite struct StorePronunciationTests {
    @Test func crudReorderEnable() throws {
        let dir = try TempDir()
        let store = PronunciationStore(directory: dir.url)
        let a = PronunciationEntry(term: "A", replacement: "ay"), b = PronunciationEntry(term: "B", replacement: "bee"),
            c = PronunciationEntry(term: "C", replacement: "see"), d = PronunciationEntry(term: "D", replacement: "dee")
        for e in [a, b, c, d] { try store.save(e) }
        try store.move(fromOffsets: [0, 2], toOffset: 4)  // A, C to the end
        #expect(store.entries.map(\.term) == ["B", "D", "A", "C"])
        try store.move(fromOffsets: [3], toOffset: 0)
        #expect(store.entries.map(\.term) == ["C", "B", "D", "A"])
        try store.setEnabled(false, for: b.id)
        #expect(store.enabledEntries().map(\.term) == ["C", "D", "A"])
        var edited = d; edited.replacement = "delta"
        try store.save(edited)
        try store.delete([a.id])
        let reopened = PronunciationStore(directory: dir.url)
        #expect(reopened.entries.map(\.term) == ["C", "B", "D"])
        #expect(reopened.entries[2].replacement == "delta")
        #expect(reopened.entries[1].enabled == false)
        #expect(try observes({ store.entries }) { try store.setEnabled(true, for: b.id) })
    }

    @Test func csvRoundTripWithAwkwardFields() throws {
        let entries = [
            PronunciationEntry(term: "Nguyen", replacement: "win"),
            PronunciationEntry(term: "a, b", replacement: "say \"ab\"", caseSensitive: true),
            PronunciationEntry(term: "multi", replacement: "line\nvalue", enabled: false),
            PronunciationEntry(term: "Zoë", replacement: " padded "),
        ]
        let csv = PronunciationStore.csv(entries)
        #expect(csv.hasPrefix("term,replacement,case_sensitive,enabled\r\n"))
        let back = try PronunciationStore.parseCSV(csv)
        #expect(back.map(\.term) == entries.map(\.term))
        #expect(back.map(\.replacement) == ["win", "say \"ab\"", "line\nvalue", "padded"])
        #expect(back.map(\.caseSensitive) == [false, true, false, false])
        #expect(back.map(\.enabled) == [true, true, false, true])
    }

    @Test func csvVariants() throws {
        let semicolons = try PronunciationStore.parseCSV("\u{FEFF}GIF;jif;yes\nSQL;sequel\n\n")
        #expect(semicolons.map(\.term) == ["GIF", "SQL"])
        #expect(semicolons[0].caseSensitive && !semicolons[1].caseSensitive)
        let tabs = try PronunciationStore.parseCSV("term\treplacement\nfoo\tbar\n")
        #expect(tabs.map(\.replacement) == ["bar"])
        #expect(throws: StoreError.self) { try PronunciationStore.parseCSV("lonely\n") }
    }

    @Test func importMergeReplaceAndJSON() throws {
        let dir = try TempDir()
        let store = PronunciationStore(directory: dir.url)
        try store.save(PronunciationEntry(term: "Nguyen", replacement: "nu-yen"))
        let csv = dir.url.appendingPathComponent("list.csv")
        try "term,replacement\nnguyen,win\nGIF,jif\n".write(to: csv, atomically: true, encoding: .utf8)
        #expect(try store.importFile(at: csv) == .init(added: 1, updated: 1))
        #expect(store.entries.map(\.replacement) == ["win", "jif"])

        let json = dir.url.appendingPathComponent("list.json")
        try store.export(to: json)
        let other = PronunciationStore(directory: dir.url.appendingPathComponent("other"))
        try other.importFile(at: json, replacing: true)
        #expect(other.entries == store.entries)

        let csvOut = dir.url.appendingPathComponent("out.csv")
        try store.export(to: csvOut)
        let third = PronunciationStore(directory: dir.url.appendingPathComponent("third"))
        try third.importFile(at: csvOut)
        #expect(third.entries.map(\.term) == store.entries.map(\.term))
    }
}

// MARK: - Settings

@MainActor @Suite struct StoreSettingsTests {
    /// A throwaway suite in a temp folder (never ~/Library/Preferences), deleted when the test process exits.
    func freshDefaults() -> UserDefaults { ThrowawayDefaults.make("EncoreTests").defaults }

    @Test func persistsAndRestores() async throws {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        #expect(s.values == .defaults)
        s.idleUnloadMinutes = 0
        s.defaultExportFormat = .m4a
        s.ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        s.postProcessing.targetLUFS = -14
        s.setRuntimePreference(.python, for: "chatterbox")
        s.setRuntimePreference(.automatic, for: "zonos3-mini")
        s.noteModelUsed("zonos3-mini", for: .speech)
        let snapshot = await Task.detached { s.snapshot() }.value
        #expect(snapshot.defaultExportFormat == .m4a && snapshot.postProcessing.targetLUFS == -14)
        #expect(snapshot.runtimePreference(for: "chatterbox") == .python)
        #expect(snapshot.runtimePreference(for: "zonos3-mini") == .automatic)

        let restored = AppSettings(defaults: defaults)
        #expect(restored.values == s.values)
        #expect(restored.idleUnloadMinutes == 0)
        #expect(restored.lastUsedModels[.speech] == "zonos3-mini")
        s.idleUnloadMinutes = -5
        #expect(s.idleUnloadMinutes == 0)
        s.resetToDefaults()
        #expect(AppSettings(defaults: defaults).values == .defaults)
    }

    @Test func tolerantOfOldOrForeignData() throws {
        let defaults = freshDefaults()
        let json = #"{"idleUnloadMinutes": 3, "defaultExportFormat": "ogg", "preferredRuntimes": {"a": "python", "b": "cuda"}, "lastUsedModels": {"speech": "x", "karaoke": "y"}, "futureKey": true}"#
        defaults.set(Data(json.utf8), forKey: "EncoreSettings")
        let s = AppSettings(defaults: defaults)
        #expect(s.idleUnloadMinutes == 3)
        #expect(s.defaultExportFormat == .wav)
        #expect(s.preferredRuntimes == ["a": .python])
        #expect(s.lastUsedModels == [.speech: "x"])
    }

    @Test func observation() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(observes({ s.idleUnloadMinutes }) { s.idleUnloadMinutes = 30 })
        #expect(observes({ s.postProcessing }) { s.postProcessing.removeSilence = true })
    }
}


@Suite struct ThrowawayDefaultsTests {
    @Test func suitesNeverTouchLibraryPreferences() {
        let scratch = ThrowawayDefaults.make("EncoreThrowawayTest")
        scratch.defaults.set("x", forKey: "k")
        CFPreferencesAppSynchronize(scratch.suite as CFString)
        let folder = URL(fileURLWithPath: scratch.suite).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: scratch.suite + ".plist"))
        #expect(folder.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let leaked = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path))?
            .filter { $0.hasPrefix(folder.lastPathComponent) } ?? []
        #expect(leaked.isEmpty)
        ThrowawayDefaults.remove(scratch.suite)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
