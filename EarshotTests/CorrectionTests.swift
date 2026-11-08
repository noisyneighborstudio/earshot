import Foundation
import Testing
@testable import Earshot

struct CorrectionExtractionTests {
    private func fixes(_ pasted: String, _ current: String, startsSentence: Bool = true) -> [String] {
        CorrectionTracker.corrections(pasted: pasted, current: current, startsSentence: startsSentence)
    }

    @Test func properNounFix() {
        #expect(fixes("I take a lift every day.", "I take a Lyft every day.") == ["Lyft"])
    }

    @Test func sentenceStartCapitalizationOnly() {
        #expect(fixes("sounds good to me.", "Sounds good to me.").isEmpty)
        #expect(fixes("great. see you then", "great. See you then").isEmpty)
    }

    @Test func unchangedTextYieldsNothing() {
        #expect(fixes("Let's ship on Friday.", "Let's ship on Friday.").isEmpty)
    }

    @Test func wholesaleRewriteYieldsNothing() {
        #expect(fixes("please send the report over by tomorrow morning",
                      "Actually Kubernetes migration notes are attached here instead").isEmpty)
    }

    @Test func appendedTextStillAligns() {
        #expect(fixes("we deploy with get hub actions", "we deploy with GitHub actions and then we monitor in Datadog") == ["GitHub"])
        #expect(fixes("ask pria about it", "ask Priya about it. Also loop in Jonas.", startsSentence: true) == ["Priya"])
    }

    @Test func firstLetterCasingAloneIsAmbiguous() {
        #expect(fixes("ask priya about it", "ask Priya about it").isEmpty)
    }

    @Test func mixedCaseAndDigits() {
        #expect(fixes("it runs on ios and mac", "it runs on iOS and mac") == ["iOS"])
        #expect(fixes("check the s3 bucket", "check the S3 bucket") == ["S3"])
    }

    @Test func lowercaseWordSwapsAreIgnored() {
        #expect(fixes("their going to the store", "they're going to the store").isEmpty)
        #expect(fixes("the meeting is at noon", "the meeting is at nine").isEmpty)
    }

    @Test func unrelatedReplacementIsIgnored() {
        // A capitalized but dissimilar word is a different word, not a fix.
        #expect(fixes("talk to the vendor today", "talk to the Acme today").isEmpty)
    }

    @Test func shortDictationCanStillBeCorrected() {
        #expect(fixes("lift", "Lyft", startsSentence: false) == ["Lyft"])
    }

    @Test func duplicatesCollapse() {
        #expect(fixes("lift is great and lift is fast", "Lyft is great and Lyft is fast") == ["Lyft"])
    }

    @Test func punctuationOnlyChangesIgnored() {
        #expect(fixes("ok so lets go", "Ok, so let's go!").isEmpty)
    }
}

struct CorrectionRegionTests {
    @Test func findsTextAfterAnchor() {
        let field = "Hi team, quick update. I take a Lyft every day."
        let region = CorrectionTracker.region(in: field, after: "Hi team, quick update. ", pastedWordCount: 6)
        #expect(region == "I take a Lyft every day.")
    }

    @Test func toleratesEditsBeforeTheInsert() {
        // The start of the anchor was edited; a shorter suffix still matches.
        let anchor = "Hello everyone and welcome to the weekly sync for the platform team. Today: "
        let field = "Hi folks, welcome to the weekly sync for the platform team. Today: deploy with GitHub"
        #expect(CorrectionTracker.region(in: field, after: anchor, pastedWordCount: 3) == "deploy with GitHub")
    }

    @Test func missingAnchorIsNil() {
        #expect(CorrectionTracker.region(in: "totally different text", after: "an anchor that is gone now", pastedWordCount: 3) == nil)
    }

    @Test func emptyAnchorUsesWholeField() {
        #expect(CorrectionTracker.region(in: "Lyft is great", after: "", pastedWordCount: 3) == "Lyft is great")
    }

    @Test func regionIsBoundedAroundThePasteLength() {
        let field = "Start: " + Array(repeating: "word", count: 100).joined(separator: " ")
        let region = CorrectionTracker.region(in: field, after: "Start:", pastedWordCount: 2)
        #expect(region?.split(separator: " ").count == 9)
    }

    @Test func sentenceStartFromAnchor() {
        #expect(CorrectionTracker.endsSentence(""))
        #expect(CorrectionTracker.endsSentence("Done. "))
        #expect(!CorrectionTracker.endsSentence("I talked to"))
    }

    @Test func endToEndFromField() {
        let before = "Thanks for the demo, "
        let pasted = "I'll share it with pria and the get hub team."
        let field = before + "I'll share it with Priya and the GitHub team. More later."
        let region = CorrectionTracker.region(in: field, after: CorrectionTracker.anchor(before),
                                              pastedWordCount: CorrectionTracker.tokens(pasted).count)
        let found = CorrectionTracker.corrections(pasted: pasted, current: region ?? "",
                                                  startsSentence: CorrectionTracker.endsSentence(before))
        #expect(found == ["Priya", "GitHub"])
    }
}

struct CorrectionHelperTests {
    @Test func levenshtein() {
        #expect(CorrectionTracker.levenshtein("kitten", "sitting") == 3)
        #expect(CorrectionTracker.levenshtein("", "abc") == 3)
        #expect(CorrectionTracker.levenshtein("same", "same") == 0)
    }

    @Test func termHeuristic() {
        #expect(CorrectionTracker.isTerm("GitHub", atSentenceStart: true))
        #expect(CorrectionTracker.isTerm("S3", atSentenceStart: true))
        #expect(CorrectionTracker.isTerm("Priya", atSentenceStart: false))
        #expect(!CorrectionTracker.isTerm("Priya", atSentenceStart: true))
        #expect(!CorrectionTracker.isTerm("there", atSentenceStart: false))
    }
}
