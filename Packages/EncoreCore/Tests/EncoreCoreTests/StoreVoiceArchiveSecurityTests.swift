import Foundation
import Testing
@testable import EncoreCore

/// Writes uncompressed zip archives with arbitrary entry names and Unix modes, to build hostile `.encorevoice` files.
struct TestZip {
    struct Entry { var name: String; var data: Data; var mode: UInt32 = 0o100644 }
    var entries: [Entry] = []

    mutating func file(_ name: String, _ text: String) { entries.append(Entry(name: name, data: Data(text.utf8))) }
    mutating func symlink(_ name: String, to target: String) { entries.append(Entry(name: name, data: Data(target.utf8), mode: 0o120777)) }

    func write(to url: URL) throws {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for e in entries {
            let name = Data(e.name.utf8), crc = Self.crc32(e.data), offset = UInt32(out.count)
            u32(0x04034b50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(e.data.count), &out); u32(UInt32(e.data.count), &out)
            u16(name.count, &out); u16(0, &out); out.append(name); out.append(e.data)
            u32(0x02014b50, &central); u16(0x0314, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(crc, &central); u32(UInt32(e.data.count), &central)
            u32(UInt32(e.data.count), &central); u16(name.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(e.mode << 16, &central); u32(offset, &central); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        try out.write(to: url)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

@MainActor @Suite struct StoreVoiceArchiveSecurityTests {
    let dir: TempDir
    let lib: VoiceLibrary
    let id = UUID()

    init() throws {
        dir = try TempDir()
        lib = VoiceLibrary(directory: dir.url.appendingPathComponent("Voices"), deletesToTrash: false)
    }

    /// A well-formed archive's entries, so each test only adds the hostile part.
    func baseArchive() throws -> TestZip {
        var zip = TestZip()
        zip.file("encorevoice.json", #"{"format":"encorevoice","version":1,"voices":["\#(id.uuidString)"]}"#)
        let voice = Voice(id: id, name: "Evil", origin: .cloned, transcript: "hi", duration: 1)
        zip.file("\(id.uuidString)/voice.json", String(decoding: try StoreFiles.encoder.encode(voice), as: UTF8.self))
        return zip
    }

    /// Consent is given, so a refusal comes from the archive checks and not from the consent rule. Looking inside
    /// first (as the import sheet does) is refused the same way.
    func expectRefused(_ zip: TestZip, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let url = dir.url.appendingPathComponent("hostile-\(UUID().uuidString).encorevoice")
        try zip.write(to: url)
        await #expect(throws: StoreError.self, sourceLocation: sourceLocation) { try await lib.inspectArchive(url) }
        await #expect(throws: StoreError.self, sourceLocation: sourceLocation) { try await lib.importVoices(from: url, consentConfirmedAt: Date()) }
        #expect(lib.voices.isEmpty, sourceLocation: sourceLocation)
    }

    /// Files a hostile entry might have produced outside the extraction folder.
    func escapedFiles(named name: String) -> [String] {
        let tmp = FileManager.default.temporaryDirectory
        return [tmp.appendingPathComponent(name).path, dir.url.appendingPathComponent(name).path, "/tmp/\(name)"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    @Test func wellFormedTestArchiveImports() async throws {
        var zip = try baseArchive()
        zip.file("\(id.uuidString)/reference.wav", "RIFF")
        let url = dir.url.appendingPathComponent("good.encorevoice")
        try zip.write(to: url)
        let imported = try await lib.importVoices(from: url, consentConfirmedAt: Date())
        #expect(imported.map(\.name) == ["Evil"])
        #expect(try Data(contentsOf: lib.referenceAudioURL(for: imported[0].id)!) == Data("RIFF".utf8))
    }

    @Test func symlinkReferenceIsRefused() async throws {
        var zip = try baseArchive()
        zip.symlink("\(id.uuidString)/reference.wav", to: "/etc/passwd")
        try await expectRefused(zip)
    }

    @Test func symlinkDirectoryIsRefused() async throws {
        var zip = try baseArchive()
        zip.symlink("escape", to: "/tmp")
        zip.file("escape/encore-escaped-\(id.uuidString).txt", "pwned")
        try await expectRefused(zip)
        #expect(escapedFiles(named: "encore-escaped-\(id.uuidString).txt").isEmpty)
    }

    @Test func dotDotEntryIsRefused() async throws {
        var zip = try baseArchive()
        zip.file("\(id.uuidString)/reference.wav", "RIFF")
        zip.file("../encore-dotdot-\(id.uuidString).txt", "pwned")
        zip.file("\(id.uuidString)/../../encore-dotdot2-\(id.uuidString).txt", "pwned")
        try await expectRefused(zip)
        #expect(escapedFiles(named: "encore-dotdot-\(id.uuidString).txt").isEmpty)
        #expect(escapedFiles(named: "encore-dotdot2-\(id.uuidString).txt").isEmpty)
    }

    @Test func absolutePathEntryIsRefused() async throws {
        var zip = try baseArchive()
        zip.file("\(id.uuidString)/reference.wav", "RIFF")
        zip.file("/tmp/encore-absolute-\(id.uuidString).txt", "pwned")
        try await expectRefused(zip)
        #expect(escapedFiles(named: "encore-absolute-\(id.uuidString).txt").isEmpty)
    }

    @Test func dittoMadeSymlinkArchiveIsRefused() async throws {
        // The same thing produced by the system archiver, as a stranger's Mac would.
        let src = dir.url.appendingPathComponent("src")
        let folder = src.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = try baseArchive()
        try zip.entries[0].data.write(to: src.appendingPathComponent("encorevoice.json"))
        try zip.entries[1].data.write(to: folder.appendingPathComponent("voice.json"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("reference.wav").path,
                                                   withDestinationPath: "/etc/hosts")
        let url = dir.url.appendingPathComponent("ditto.encorevoice")
        try await StoreFiles.run("/usr/bin/ditto", ["-c", "-k", src.path, url.path])
        await #expect(throws: StoreError.self) { try await lib.importVoices(from: url, consentConfirmedAt: Date()) }
        #expect(lib.voices.isEmpty)
    }

    @Test func oddReferenceNamesAreIgnored() async throws {
        var zip = try baseArchive()
        zip.file("\(id.uuidString)/reference.wav.sh", "#!/bin/sh")
        zip.file("\(id.uuidString)/reference.", "x")
        try await expectRefused(zip)  // no valid reference file: incomplete
    }

    @Test func tooManyEntriesIsRefused() async throws {
        var zip = try baseArchive()
        zip.file("\(id.uuidString)/reference.wav", "RIFF")
        for i in 0...VoiceLibrary.maxArchiveEntries { zip.file("junk/\(i)", "") }
        try await expectRefused(zip)
    }
}
