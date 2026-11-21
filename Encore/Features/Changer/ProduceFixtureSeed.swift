#if DEBUG
import EncoreCore
import SwiftUI

/// Seeding shared by the Changer, Conversations and Transcribe fixtures. Snapshot mode already runs on throwaway
/// stores in a temporary folder with an empty model cache; these helpers only write into those.
@MainActor
enum ProduceFixtureSeed {
    static func arg(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard SnapshotConfig(arguments: a) != nil, let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// The snapshot's temporary root (next to its history and voices).
    static func mediaFolder(_ deps: AppDependencies) -> URL {
        let dir = deps.service.history.directory.deletingLastPathComponent().appendingPathComponent("FixtureMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Marks models as downloaded: a snapshot folder with one file per repo is enough for the service to accept them.
    static func markDownloaded(_ deps: AppDependencies, _ ids: [String], runtimes: [String: EngineRuntime] = [:]) async {
        let layout = deps.service.hub.layout
        let commit = String(repeating: "e2", count: 20)
        for id in ids {
            guard let m = deps.catalog.model(id) else { continue }
            for repo in m.defaultVariant.allRepos {
                let ref = layout.refFile(repo, ref: "main")
                let snap = layout.snapshotDirectory(repo, commit: commit)
                try? FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
                try? Data(commit.utf8).write(to: ref)
                try? Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
            }
        }
        let shelf = deps.modelShelf
        shelf.rescan()
        await shelf.waitForScan()
        for (id, r) in runtimes { shelf.runtimeOverrides[id] = .runs(r) }
    }

    struct Cast { var captain: UUID; var mira: UUID; var tom: UUID; var juniper: UUID }

    /// A small company of voices with synthesized reference clips.
    static func addVoices(_ deps: AppDependencies) async -> Cast {
        let tmp = mediaFolder(deps).appendingPathComponent("voices-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let specs: [(Voice, Double)] = [
            (Voice(name: "Captain Reyes", tags: ["narration", "warm", "low"], origin: .cloned, transcript: "Steady as she goes.",
                   language: "en", duration: 8.4, consentConfirmedAt: Date()), 110),
            (Voice(name: "Mira", tags: ["bright", "young"], origin: .designed, transcript: "Hello there.",
                   designPrompt: "A bright young woman, quick and amused", duration: 6.1), 210),
            (Voice(name: "Old Tom", tags: ["gravel", "storyteller"], origin: .imported, transcript: "Back in my day.", duration: 11.2), 95),
            (Voice(name: "Juniper", tags: ["calm", "radio"], origin: .cloned, transcript: "Good evening.", duration: 7.3,
                   consentConfirmedAt: Date()), 180),
        ]
        var ids: [UUID] = []
        for (i, (v, pitch)) in specs.enumerated() {
            let url = tmp.appendingPathComponent("voice-\(i).wav")
            try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: v.duration, seed: i + 1, pitch: pitch), to: url)
            let saved = try? await deps.voices.add(v, referenceAudio: url, move: true)
            ids.append(saved?.id ?? v.id)
        }
        try? FileManager.default.removeItem(at: tmp)
        return Cast(captain: ids[0], mira: ids[1], tom: ids[2], juniper: ids[3])
    }

    /// Writes a speech-shaped WAV of `seconds` and returns its URL.
    static func audio(_ deps: AppDependencies, name: String, seconds: Double, seed: Int, pitch: Double) -> URL {
        let url = mediaFolder(deps).appendingPathComponent(name)
        try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: seconds, seed: seed, pitch: pitch), to: url)
        return url
    }

    /// A generation record with real audio in the snapshot's history.
    @discardableResult
    static func insertGeneration(_ deps: AppDependencies, kind: GenerationRecord.Kind, title: String, text: String, modelID: String,
                                 voiceName: String?, voiceID: UUID? = nil, seconds: Double, seed: Int, pitch: Double,
                                 ago: TimeInterval) async -> GenerationRecord {
        let id = UUID()
        let url = deps.service.history.newAudioURL(id: id)
        try? AudioExporter.writeWAV(StudioFixtures.speechLike(seconds: seconds, seed: seed, pitch: pitch), to: url)
        let m = deps.catalog.model(modelID)
        let record = GenerationRecord(id: id, kind: kind, title: title, text: text, modelID: modelID, modelName: m?.name ?? modelID,
                                      voiceName: voiceName, voiceID: voiceID, parameters: m?.defaultParameters ?? [:],
                                      audioPath: url.path, duration: seconds, sampleRate: 24_000,
                                      createdAt: Date().addingTimeInterval(-ago), elapsed: seconds * 0.4)
        try? await deps.service.history.insert(record)
        return record
    }
}
#endif
