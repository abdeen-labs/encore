import Foundation

extension SpeechRequest {
    /// A "hear it" try-out of a voice just cloned or designed: one line spoken with the library voice. Try-outs are
    /// not kept in History (`saveToHistory` is false), so the result's audio is a scratch file the caller deletes.
    public static func voiceTryout(_ voice: Voice, modelID: String, variantID: String?, text: String, language: String?) -> SpeechRequest {
        var r = SpeechRequest(modelID: modelID, text: text)
        r.variantID = variantID
        r.voice = .library(voice.id)
        r.language = language
        r.title = "\(voice.name) — first words"
        r.saveToHistory = false
        return r
    }
}
