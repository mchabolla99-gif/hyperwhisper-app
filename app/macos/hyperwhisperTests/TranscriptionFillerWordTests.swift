//
//  TranscriptionFillerWordTests.swift
//  hyperwhisperTests
//

import Testing
@testable import HyperWhisper

struct TranscriptionFillerWordTests {
    @Test func stripsFillersForEnglish() {
        let result = TranscriptionTextProcessing.removeFillerWords(
            "so uh I think we should um go",
            language: "en"
        )

        #expect(result == "so I think we should go")
    }

    @Test func stripsFillersForEnglishRegionalVariants() {
        let result = TranscriptionTextProcessing.removeFillerWords(
            "well er maybe later",
            language: "en-GB"
        )

        #expect(result == "well maybe later")
    }

    @Test func preservesGermanRealWords() {
        // "er" = he, "um" = at — both are real German words, not fillers.
        #expect(
            TranscriptionTextProcessing.removeFillerWords("ich denke er ist groß", language: "de")
                == "ich denke er ist groß"
        )
        #expect(
            TranscriptionTextProcessing.removeFillerWords("Wir treffen uns um drei Uhr", language: "de")
                == "Wir treffen uns um drei Uhr"
        )
    }

    @Test func skipsWhenLanguageIsUnknown() {
        // nil corresponds to "auto" — ambiguous, so we leave the text untouched.
        #expect(
            TranscriptionTextProcessing.removeFillerWords("ich denke er ist groß", language: nil)
                == "ich denke er ist groß"
        )
    }

    @Test func stripsSentenceOpeningFiller() {
        // Filler at the very start of the text — already capitalized next word.
        #expect(
            TranscriptionTextProcessing.removeFillerWords("Uh, I think we should go", language: "en")
                == "I think we should go"
        )
    }

    @Test func recapitalizesAfterStrippingLeadingFiller() {
        // Next word was lowercase because the STT treated the filler as the opener.
        #expect(
            TranscriptionTextProcessing.removeFillerWords("um, the cat sat down", language: "en")
                == "The cat sat down"
        )
        #expect(
            TranscriptionTextProcessing.removeFillerWords("uh the meeting starts soon", language: "en")
                == "The meeting starts soon"
        )
    }

    @Test func stripsFillerFollowedByComma() {
        // Mid-sentence "uh," — comma was previously left dangling.
        #expect(
            TranscriptionTextProcessing.removeFillerWords("so uh, I think we should go", language: "en")
                == "so I think we should go"
        )
        // Filler between two clauses, surrounded by commas.
        #expect(
            TranscriptionTextProcessing.removeFillerWords("I think, uh, we should go", language: "en")
                == "I think, we should go"
        )
    }

    @Test func stripsFillerEndingText() {
        #expect(
            TranscriptionTextProcessing.removeFillerWords("I think we should go uh", language: "en")
                == "I think we should go"
        )
    }

    // MARK: - processConfirmedStreamingDelta (streaming confirmed-delta pipeline)

    @Test func streamingDeltaStripsFillersWhenEnabledForEnglish() {
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "so uh I think we should um go",
            language: "en",
            removeFillerWords: true,
            vocabulary: []
        )

        #expect(result == "so I think we should go")
    }

    @Test func streamingDeltaLeavesFillersWhenSettingDisabled() {
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "so uh I think we should um go",
            language: "en",
            removeFillerWords: false,
            vocabulary: []
        )

        #expect(result == "so uh I think we should um go")
    }

    @Test func streamingDeltaPreservesNonEnglishRealWordsEvenWhenEnabled() {
        // "er"/"um" are real German words — the language gate inside
        // removeFillerWords must still protect them here, even though the
        // setting itself is enabled.
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "ich denke er ist groß",
            language: "de",
            removeFillerWords: true,
            vocabulary: []
        )

        #expect(result == "ich denke er ist groß")
    }

    @Test func streamingDeltaSkipsFillerRemovalWhenLanguageIsUnknown() {
        // nil corresponds to auto-detect — ambiguous, so the pipeline leaves
        // filler words untouched even with the setting enabled.
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "so uh I think we should um go",
            language: nil,
            removeFillerWords: true,
            vocabulary: []
        )

        #expect(result == "so uh I think we should um go")
    }

    @Test func streamingDeltaAppliesVoiceCommandsAfterFillerRemoval() {
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "so uh new line let's continue",
            language: "en",
            removeFillerWords: true,
            vocabulary: []
        )

        #expect(result == "so \n\n let's continue")
    }

    @Test func streamingDeltaAppliesVocabularyAfterFillerRemovalAndVoiceCommands() {
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "so uh kubernetes is great",
            language: "en",
            removeFillerWords: true,
            vocabulary: [VocabularyEntrySnapshot(word: "kubernetes", replacement: "Kubernetes")]
        )

        #expect(result == "so Kubernetes is great")
    }

    @Test func streamingDeltaRecapitalizesLeadingFillerOnlyForFirstConfirmedDelta() {
        // The FIRST confirmed delta of a session mirrors the batch path: a
        // leading filler really is a sentence opener, so the word after it
        // should be recapitalized. isFirstConfirmedDelta defaults to true, so
        // this matches existing call sites that don't pass it explicitly.
        let first = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "um, the cat sat down",
            language: "en",
            removeFillerWords: true,
            vocabulary: []
        )
        #expect(first == "The cat sat down")

        // A LATER delta is mid-transcript, not a new sentence — a leading
        // filler there (e.g. following an earlier confirmed "I think") must
        // not force-capitalize the next word into "I think This works".
        let later = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "um, this works",
            language: "en",
            removeFillerWords: true,
            vocabulary: [],
            isFirstConfirmedDelta: false
        )
        #expect(later == "this works")
    }

    @Test func streamingDeltaLeavesAlreadyUppercaseLeadingWordAloneForLaterDeltas() {
        // If the raw delta already opened uppercase, removeFillerWords didn't
        // recapitalize anything — a later delta shouldn't force it lowercase.
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "Um, The cat sat down",
            language: "en",
            removeFillerWords: true,
            vocabulary: [],
            isFirstConfirmedDelta: false
        )
        #expect(result == "The cat sat down")
    }

    @Test func streamingDeltaRevertsRecapitalizationEvenWhenSttCapitalizedTheFiller() {
        // Under-reversion regression: the STT commonly capitalizes a filler as
        // if it were a sentence opener ("Um, this works") even mid-transcript.
        // The raw delta's first character is therefore already uppercase, but
        // removeFillerWords still forces a capital on the surviving word — a
        // later delta must still revert that, since the actual signal is
        // whether the word AFTER the filler was originally lowercase, not the
        // filler's own casing.
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "Um, this works",
            language: "en",
            removeFillerWords: true,
            vocabulary: [],
            isFirstConfirmedDelta: false
        )
        #expect(result == "this works")
    }

    @Test func streamingDeltaPreservesRealProperNounAfterLowercaseFiller() {
        // Over-reversion regression: "um, Paris is beautiful" opens with a
        // lowercase filler, but the surviving word ("Paris") is a genuine
        // proper noun that was already uppercase in the raw input —
        // removeFillerWords's forced-uppercase step is a no-op here, so there
        // is nothing to revert. A later delta must NOT lowercase it to
        // "paris" just because the raw text happened to open lowercase.
        let result = TranscriptionTextProcessing.processConfirmedStreamingDelta(
            "um, Paris is beautiful",
            language: "en",
            removeFillerWords: true,
            vocabulary: [],
            isFirstConfirmedDelta: false
        )
        #expect(result == "Paris is beautiful")
    }
}
