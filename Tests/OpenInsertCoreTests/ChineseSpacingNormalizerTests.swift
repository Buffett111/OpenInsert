import XCTest
@testable import OpenInsertCore

final class ChineseSpacingNormalizerTests: XCTestCase {
    func testReportedASRExampleWithoutChangingEnglishBoundarySpaces() {
        let original = "有 時 候 gemini 會 自 動 修 復，但 有 時 候 呢 ， 它 就 是 會 在 每 個 中 文 字 之 間 都 保 留 空 格"
        let expected = "有時候 gemini 會自動修復，但有時候呢，它就是會在每個中文字之間都保留空格"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize(original), expected)
    }

    func testEnglishWordsNumbersAndTheirChineseBoundariesRemainSpaced() {
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("使 用 Gemini API 3.5 第 2 次 及 GPT 4 的 回 答"),
                       "使用 Gemini API 3.5 第 2 次及 GPT 4 的回答")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("hello world 123 456"), "hello world 123 456")
    }

    func testChinesePunctuationAndBracketsJoinOnlyWithHan() {
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 ， 文 。 中 ！ 文 ？ 中 ； 文 ： 中 、 文"),
                       "中，文。中！文？中；文：中、文")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("「 中 文 」 與 （ 漢 字 ）"), "「中文」與（漢字）")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 ， 。 文 ， English ， 2"), "中， 。文， English ， 2")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 , 文 ... 中 — 文"), "中 , 文 ... 中 — 文")
    }

    func testParagraphsAndLineEndingsArePreservedExactly() {
        let text = " 中 文 \r\n\r\n簡 體\n下 一 行\r末 行\u{2028}另 一 行\u{2029}"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize(text), " 中文 \r\n\r\n簡體\n下一行\r末行\u{2028}另一行\u{2029}")
    }

    func testTabsAndMultipleSpaceLayoutAreNotCollapsed() {
        let text = "  中 文\t漢 字  對 齊   表 格\n\t中 文\t\t漢 字"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize(text), "  中文\t漢字  對齊   表格\n\t中 文\t\t漢 字")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 \u{00A0}文\n中\u{3000}\u{3000}文"),
                       "中 \u{00A0}文\n中\u{3000}\u{3000}文")
    }

    func testSingleUnicodeHorizontalSpacesIncludingNonbreakingAndIdeographic() {
        for space in [" ", "\u{00A0}", "\u{1680}", "\u{2002}", "\u{2009}", "\u{202F}", "\u{205F}", "\u{3000}"] {
            XCTAssertEqual(ChineseSpacingNormalizer.normalize("中\(space)文\(space)，\(space)字"), "中文，字")
            XCTAssertEqual(ChineseSpacingNormalizer.normalize("中\(space)API\(space)2"), "中\(space)API\(space)2")
        }
    }

    func testTraditionalAndSimplifiedFormsAreNotConverted() {
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("語 音 輸 入 与 语 音 输 入"), "語音輸入与语音输入")
    }

    func testSupplementaryHanAndIdeographicVariationSelectorsRemainIntact() {
        let variant = "禰\u{E0100}"
        let basicSelector = "漢\u{FE00}"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("𠮷 \(variant) \(basicSelector) 𠀀"), "𠮷\(variant)\(basicSelector)𠀀")
    }

    func testEmojiAndCombiningSequencesAreNotDamaged() {
        let text = "中 👨‍👩‍👧‍👦 文 👍🏽 字 🇹🇼 中 ㊗️ 文 1️⃣ 字 e\u{301} 中"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize(text), text)
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 👩🏽‍💻 漢 字"), "中文 👩🏽‍💻 漢字")
    }

    func testJapaneseKanaProtectsWholeLineButNotFollowingChineseLine() {
        for kana in ["の", "カ", "ｶ", "\u{1B000}"] {
            let first = "中 文 日本 語 \(kana) 漢 字"
            XCTAssertEqual(ChineseSpacingNormalizer.normalize(first + "\n中 文"), first + "\n中文")
        }
    }

    func testKoreanHangulProtectsWholeLineIncludingDecomposedAndHalfwidthForms() {
        for hangul in ["한국어", "한", "ㄱ", "\u{FFA1}"] {
            let first = "中 文 \(hangul) 漢 字"
            XCTAssertEqual(ChineseSpacingNormalizer.normalize(first + "\r\n中 文"), first + "\r\n中文")
        }
    }

    func testInlineCodeAndDifferentBacktickDelimiterLengthsRemainLiteral() {
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 `中 文  =  2` 漢 字"), "中文 `中 文  =  2` 漢字")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 ``中 ` 文`` 漢 字"), "中文 ``中 ` 文`` 漢字")
    }

    func testMultilineAndUnclosedInlineCodeArePreservedConservatively() {
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 `中 文\n漢 字` 下 一 行"), "中文 `中 文\n漢 字` 下一行")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 `尚 未 結 束\n仍 在 輸 入"), "中文 `尚 未 結 束\n仍 在 輸 入")
    }

    func testEscapedBacktickDoesNotHideOrdinaryChineseProse() {
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 \\` 漢 字"), "中文 \\` 漢字")
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("中 文 \\``漢 字` 後 文"), "中文 \\``漢 字` 後文")
    }

    func testBacktickAndTildeFencedCodeArePreservedIncludingInfoAndIndentation() {
        let fenced = "   ```中 文\r\n中 文 = 2\r\n   ```\r\n~~~txt\n漢 字\n~~~\n"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("前 文\n" + fenced + "後 文"), "前文\n" + fenced + "後文")
    }

    func testShorterOrMismatchedFenceCannotExposeCodeToNormalization() {
        let code = "````text\n中 文\n```\n仍 是 程 式 碼\n~~~~\n也 是 程 式 碼\n````\n"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize(code + "後 文"), code + "後文")
    }

    func testUnclosedFencePreservesAllRemainingText() {
        let code = "~~~\n中 文\n漢 字"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("前 文\n" + code), "前文\n" + code)
    }

    func testIndentedCodePreservesStringContentsWithoutOpeningInlineSpans() {
        let code = "    let value = \"中 文\";\n\tlet label = \"漢 字\";\n  \tlet marker = \"`\";\n"
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("前 文\n" + code + "後 文"), "前文\n" + code + "後文")
        // Three leading spaces can still be ordinary Chinese prose.
        XCTAssertEqual(ChineseSpacingNormalizer.normalize("   中 文"), "   中文")
    }

    func testNormalizationIsIdempotentAcrossMixedContent() {
        let samples = ["", " ", "中 文 ， 漢 字 API 123", "中  文\t漢 字\n中\u{00A0}文",
                       "中 文 `漢 字` 中 文", "```\n中 文\n```\n漢 字", "中 文 한국어\n漢 字",
                       "禰\u{E0100} 𠮷 👩🏽‍💻 中 文"]
        for sample in samples {
            let once = ChineseSpacingNormalizer.normalize(sample)
            XCTAssertEqual(ChineseSpacingNormalizer.normalize(once), once, sample)
        }
    }
}
