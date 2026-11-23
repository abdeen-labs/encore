import EncoreCore
import Foundation
import Tokenizers

/// OmniVoice's text tokenizer, with each sound tag tokenized on its own as the Python port does. The Swift port
/// tokenizes the whole script in one go, which merges a tag with the space or punctuation around it into tokens the
/// model never saw for that tag, so it reads "[sigh]" out as a word. See `OmniVoiceTags`.
struct OmniVoiceTagTokenizer: Tokenizer {
    let base: any Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        // OmniVoice only encodes without special tokens; splitting with them would repeat BOS/EOS per segment.
        guard !addSpecialTokens else { return base.encode(text: text, addSpecialTokens: true) }
        return OmniVoiceTags.segments(text).flatMap { base.encode(text: String($0), addSpecialTokens: false) }
    }

    func encode(text: String) -> [Int] { encode(text: text, addSpecialTokens: true) }
    func callAsFunction(_ text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text, addSpecialTokens: addSpecialTokens) }

    // Everything else is the base tokenizer's.
    func tokenize(text: String) -> [String] { base.tokenize(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokens, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertTokensToIds(_ tokens: [String]) -> [Int?] { base.convertTokensToIds(tokens) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func convertIdsToTokens(_ ids: [Int]) -> [String?] { base.convertIdsToTokens(ids) }
    var bosToken: String? { base.bosToken }
    var bosTokenId: Int? { base.bosTokenId }
    var eosToken: String? { base.eosToken }
    var eosTokenId: Int? { base.eosTokenId }
    var unknownToken: String? { base.unknownToken }
    var unknownTokenId: Int? { base.unknownTokenId }
    var hasChatTemplate: Bool { base.hasChatTemplate }

    func applyChatTemplate(messages: [Message]) throws -> [Int] {
        try base.applyChatTemplate(messages: messages)
    }

    func applyChatTemplate(messages: [Message], tools: [ToolSpec]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools)
    }

    func applyChatTemplate(messages: [Message], tools: [ToolSpec]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }

    func applyChatTemplate(messages: [Message], chatTemplate: ChatTemplateArgument) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate)
    }

    func applyChatTemplate(messages: [Message], chatTemplate: String) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate)
    }

    func applyChatTemplate(
        messages: [Message], chatTemplate: ChatTemplateArgument?, addGenerationPrompt: Bool, truncation: Bool,
        maxLength: Int?, tools: [ToolSpec]?
    ) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate, addGenerationPrompt: addGenerationPrompt,
                                   truncation: truncation, maxLength: maxLength, tools: tools)
    }

    func applyChatTemplate(
        messages: [Message], chatTemplate: ChatTemplateArgument?, addGenerationPrompt: Bool, truncation: Bool,
        maxLength: Int?, tools: [ToolSpec]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate, addGenerationPrompt: addGenerationPrompt,
                                   truncation: truncation, maxLength: maxLength, tools: tools,
                                   additionalContext: additionalContext)
    }
}
