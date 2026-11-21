import Foundation

public enum AudioError: LocalizedError, Sendable, Equatable {
    /// Neither AVFoundation nor ffmpeg could open the file. `reason` is the underlying message.
    case unreadable(path: String, reason: String)
    /// The file opened but has no audio track (e.g. a silent screen recording).
    case noAudioTrack(path: String)
    /// AVFoundation can't open this container and ffmpeg isn't installed.
    case needsFFmpegToRead(path: String)
    /// ffmpeg is required for this operation (MP3 export) and wasn't found.
    case ffmpegMissing(purpose: String)
    case ffmpegFailed(status: Int32, message: String)
    case writeFailed(path: String, reason: String)
    case invalidArgument(String)
    case microphonePermissionDenied
    case recordingFailed(String)
    case playbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            "Couldn't read “\((path as NSString).lastPathComponent)”: \(reason)"
        case .noAudioTrack(let path):
            "“\((path as NSString).lastPathComponent)” has no audio track."
        case .needsFFmpegToRead(let path):
            "macOS can't open “\((path as NSString).lastPathComponent)” on its own. Install ffmpeg (brew install ffmpeg) "
                + "or set its location in Settings, then try again."
        case .ffmpegMissing(let purpose):
            "\(purpose) needs ffmpeg, which wasn't found. Install it with Homebrew (brew install ffmpeg) "
                + "or set its location in Settings."
        case .ffmpegFailed(let status, let message):
            "ffmpeg failed (exit \(status)): \(message)"
        case .writeFailed(let path, let reason):
            "Couldn't write “\((path as NSString).lastPathComponent)”: \(reason)"
        case .invalidArgument(let message):
            message
        case .microphonePermissionDenied:
            "Encore doesn't have permission to use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .recordingFailed(let message):
            "Recording failed: \(message)"
        case .playbackFailed(let message):
            "Playback failed: \(message)"
        }
    }
}
