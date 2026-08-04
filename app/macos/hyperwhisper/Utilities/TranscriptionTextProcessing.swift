//
//  TranscriptionTextProcessing.swift
//  hyperwhisper
//
//  Facade over the shared Rust core (`hw-text`) for tag cleanup, streaming
//  sanitization, filler-word removal and voice commands. The logic lives in
//  Rust so macOS and Windows stay in lockstep; these are thin delegating shims.
//
//  The global UniFFI binding functions share base names with these facade
//  methods, so they're qualified with the module name (`HyperWhisper.`) to defeat
//  member-shadowing (an unqualified call would resolve back to the member).
//

import Foundation

enum TranscriptionTextProcessing {

    /// Extract content between `<<CLEANED>>` and `<<END>>` markers from a
    /// post-processing response. STRICT: returns "" when no start marker is
    /// present (the model didn't honour the wrapping contract) — callers fall
    /// back to the original transcription. Use `stripWrapperMarkers` for plain
    /// transcription text that may not be wrapped.
    static func extractCleanedFromWrapped(_ text: String) -> String {
        HyperWhisper.extractCleanedFromWrapped(text: text)
    }

    /// Lenient wrapper handling for plain transcription text: extract wrapped
    /// content if present, otherwise return the text (stray markers stripped).
    static func stripWrapperMarkers(_ text: String) -> String {
        HyperWhisper.stripWrapperMarkers(text: text)
    }

    /// For streaming display: drop everything before `<<CLEANED>>`, remove tag variants.
    static func sanitizeStreamingBuffer(_ buffer: String) -> String {
        HyperWhisper.sanitizeStreamingBuffer(buffer: buffer)
    }

    /// Remove a single trailing period (preserves an ellipsis "...").
    static func removeTrailingPeriod(_ text: String) -> String {
        HyperWhisper.removeTrailingPeriod(text: text)
    }

    /// Remove English filler words ("uh", "um", "er"). No-op for non-English /
    /// unknown languages (those are real words elsewhere).
    static func removeFillerWords(_ text: String, language: String?) -> String {
        HyperWhisper.removeFillerWords(text: text, language: language)
    }

    /// Replace the spoken "new line" command with a paragraph break.
    static func processVoiceCommands(_ text: String) -> String {
        HyperWhisper.processVoiceCommands(text: text)
    }

    /// Split a transcript at the breaks the user dictated ("new line" /
    /// "new paragraph"), returning one segment per paragraph. A transcript with
    /// no dictated break yields a single segment (the text itself).
    ///
    /// Reuses the shared core's command regex — `processVoiceCommands` turns each
    /// command into a paragraph break, so splitting on the break it produced keeps
    /// macOS and Windows on exactly one definition of "what counts as a command".
    static func splitOnDictatedBreaks(_ text: String) -> [String] {
        processVoiceCommands(text)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Normalize a provider's raw termination signal (e.g. OpenAI `finish_reason`,
    /// Anthropic `stop_reason`) into a `CompletionState`. Missing `reason` yields
    /// `.unspecified` (proceeds) rather than being treated as truncation.
    static func normalizeTermination(wireProtocol: WireProtocol, reason: String?) -> CompletionState {
        HyperWhisper.normalizeTermination(wireProtocol: wireProtocol, reason: reason)
    }

    /// Apply the completion policy gate: `state` decides accept/reject; on accept,
    /// lenient marker handling extracts wrapped content (or strips stray markers)
    /// and rejects prompt leakage / empty results. `evaluation.text` is always safe
    /// to use directly — the cleaned text when accepted, `original` when rejected.
    static func evaluateCompletion(original: String, content: String, state: CompletionState) -> CompletionEvaluation {
        HyperWhisper.evaluateCompletion(original: original, content: content, state: state)
    }

    /// Convenience that parses a raw provider response body (as a JSON string),
    /// extracts the termination reason for the given wire protocol, and runs the
    /// full completion policy in one call.
    static func evaluateLlmResponseJson(wireProtocol: WireProtocol, responseJson: String, original: String) -> CompletionEvaluation {
        HyperWhisper.evaluateLlmResponseJson(wireProtocol: wireProtocol, responseJson: responseJson, original: original)
    }

    // MARK: - Streaming confirmed-delta pipeline

    /// Confirmed-delta transform for streaming transcription: filler-word
    /// removal → voice-command processing → vocabulary substitution, mirroring
    /// the batch path's order (`TranscriptionPipeline+Transcription.swift`).
    ///
    /// Extracted as a pure static function so it's directly testable without
    /// standing up `RecordingTranscriptionFlow`/`AppState`/`SettingsManager`.
    /// Only ever call this on confirmed/final deltas — applying filler removal
    /// to interim/partial text would cause words to visibly pop in and out as
    /// the partial hypothesis changes.
    ///
    /// - Parameter isFirstConfirmedDelta: Whether this is the session's first
    ///   confirmed delta. `removeFillerWords` recapitalizes the word after a
    ///   leading filler on the assumption that it is processing the START of a
    ///   whole transcript — true for the batch path, and for a session's first
    ///   delta, but WRONG for a later delta (e.g. "um, this works" following an
    ///   earlier confirmed "I think" is mid-transcript, not a new sentence).
    ///   Defaults to `true` so existing call sites/tests that don't pass it
    ///   keep today's sentence-opener behavior.
    static func processConfirmedStreamingDelta(
        _ text: String,
        language: String?,
        removeFillerWords: Bool,
        vocabulary: [VocabularyEntrySnapshot],
        isFirstConfirmedDelta: Bool = true
    ) -> String {
        var withoutFillers = removeFillerWords
            ? Self.removeFillerWords(text, language: language)
            : text

        if removeFillerWords && !isFirstConfirmedDelta {
            withoutFillers = revertMidTranscriptRecapitalization(original: text, afterFillerRemoval: withoutFillers)
        }

        var processedText = processVoiceCommands(withoutFillers)

        if !vocabulary.isEmpty {
            processedText = applyStreamingVocabulary(processedText, vocabulary: vocabulary)
        }

        return processedText
    }

    /// Case-insensitive, word-boundary-anchored exact-match vocabulary
    /// substitution. Used on the local Parakeet streaming path so that
    /// confirmed deltas benefit from the user's vocabulary before typing.
    ///
    /// Delegates to `VocabularyProcessor.applyHardenedReplacement` — the same
    /// hardened matcher the batch path uses — so streaming no longer mangles
    /// substrings (e.g. "Kat"→"Katherine" no longer rewrites "category"). This
    /// trades the previous `.diacriticInsensitive` matching for word-boundary
    /// safety, deliberately matching the batch matcher's behavior.
    private static func applyStreamingVocabulary(_ text: String, vocabulary: [VocabularyEntrySnapshot]) -> String {
        var updated = text
        for entry in vocabulary {
            guard let replacement = entry.replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !replacement.isEmpty else {
                continue
            }
            updated = VocabularyProcessor.applyHardenedReplacement(to: updated, word: entry.word, replacement: replacement)
        }
        return updated
    }

    /// Mirrors the shared Rust core's `leading_filler_re`
    /// (`^\s*\b(uh|um|er)\b`, case-insensitive) — the pattern
    /// `remove_filler_words` itself checks against the ORIGINAL text before
    /// deciding whether to force a leading capital.
    private static func leadingFillerMatchRange(in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*\b(uh|um|er)\b"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }
        return Range(match.range, in: text)
    }

    /// Undoes the sentence-opener recapitalization `removeFillerWords` applies
    /// when it isn't warranted (a non-first streaming delta).
    ///
    /// The core function only forces a capital when the ORIGINAL text's first
    /// token was a leading filler AND the character surviving right after that
    /// filler (skipping an optional comma + whitespace) was lowercase — so
    /// that's the exact condition checked here, rather than eyeballing the
    /// whole string's before/after casing (which both under- and
    /// over-reverts): a filler the STT itself capitalized ("Um, this works")
    /// still needs reverting even though its raw first character was already
    /// uppercase, while a real proper noun surviving a lowercase filler ("um,
    /// Paris is beautiful") must NOT be reverted just because the raw text
    /// opened lowercase.
    private static func revertMidTranscriptRecapitalization(
        original: String,
        afterFillerRemoval: String
    ) -> String {
        guard let resultFirst = afterFillerRemoval.first, resultFirst.isUppercase else {
            return afterFillerRemoval
        }
        guard let leadingMatchRange = leadingFillerMatchRange(in: original) else {
            return afterFillerRemoval
        }

        var index = leadingMatchRange.upperBound
        if index < original.endIndex, original[index] == "," {
            index = original.index(after: index)
        }
        while index < original.endIndex, original[index].isWhitespace {
            index = original.index(after: index)
        }

        guard index < original.endIndex, original[index].isLowercase else {
            return afterFillerRemoval
        }

        return resultFirst.lowercased() + afterFillerRemoval.dropFirst()
    }
}
