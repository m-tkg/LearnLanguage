import XCTest
@testable import LearnLanguage

/// 本文抽出の純関数群（`HTMLContentParser` の正規表現抽出・`JinaReaderFetcher` の応答パース）のテスト。
final class ExtractionTests: XCTestCase {

    func testExtractTextRemovesScriptsAndStyles() {
        let html = """
        <html><head><style>.x{color:red}</style></head>
        <body><script>bad()</script><p>本文の段落テキスト。</p></body></html>
        """
        let text = HTMLContentParser.extractText(from: html)
        XCTAssertFalse(text.contains("bad()"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertTrue(text.contains("本文の段落テキスト。"))
    }

    func testExtractTextPrefersArticleOverNav() {
        let longBody = String(repeating: "This is the real article body. ", count: 20)
        let html = """
        <body>
          <nav>Home Sales Login</nav>
          <article><p>\(longBody)</p></article>
          <footer>Copyright</footer>
        </body>
        """
        let text = HTMLContentParser.extractText(from: html)
        XCTAssertTrue(text.contains("real article body"))
        XCTAssertFalse(text.contains("Home Sales Login"))
        XCTAssertFalse(text.contains("Copyright"))
    }

    func testExtractTextPicksBodyOverRelatedCards() {
        // カード多用サイト: 短い <article> カードが複数 + 本文を含む <main>。
        // HTML長ではなくテキスト量で選ぶので、本文（main）を選ぶこと。
        let card = "<article><a href=\"/x\"><img src=\"a.jpg\"></a><h2>Some Other Article Title</h2></article>"
        let body = String(repeating: "This is the actual article body sentence. ", count: 30)
        let html = "<body>\(card)\(card)<main><p>\(body)</p></main>\(card)</body>"
        let text = HTMLContentParser.extractText(from: html)
        XCTAssertTrue(text.contains("actual article body"))
        XCTAssertFalse(text.contains("Some Other Article Title"))
    }

    func testExtractTextRemovesNavWhenNoArticleTag() {
        // <article>/<main> が無いページはナビ/ヘッダ/フッタを除去して本文だけ残す。
        let html = """
        <body>
          <nav>All3DP All3DP Pro Get Started Projects Hardware Software</nav>
          <header>Site Header Menu</header>
          <div class="dek">A new market forecast details a sixfold expansion by 2034.</div>
          <footer>Copyright 2026</footer>
        </body>
        """
        let text = HTMLContentParser.extractText(from: html)
        XCTAssertTrue(text.contains("sixfold expansion"))
        XCTAssertFalse(text.contains("Get Started"))
        XCTAssertFalse(text.contains("Site Header Menu"))
        XCTAssertFalse(text.contains("Copyright"))
    }

    func testStripHTMLDecodesEntities() {
        let text = HTMLContentParser.stripHTML("<p>Tom &amp; Jerry &#39;s&hellip;</p>")
        XCTAssertEqual(text, "Tom & Jerry 's…")
    }

    func testExtractTitlePrefersOgTitle() {
        let html = """
        <head><meta property="og:title" content="Real Article Title">
        <title>Real Article Title | Some Site</title></head>
        """
        XCTAssertEqual(HTMLContentParser.extractTitle(from: html), "Real Article Title")
    }

    func testExtractLang() {
        XCTAssertEqual(HTMLContentParser.extractLang(from: "<html lang=\"en-US\">"), "en-US")
    }

    // MARK: - ブロック検知

    func testDetectsCloudflareBlockByText() {
        XCTAssertTrue(HTMLContentParser.looksBlocked(
            text: "Sorry, you have been blocked. Please enable cookies.",
            title: "Access denied"))
    }

    func testDetectsCloudflareBlockByTitle() {
        XCTAssertTrue(HTMLContentParser.looksBlocked(
            text: "short", title: "Attention Required! | Cloudflare"))
    }

    func testLongArticleMentioningCloudflareIsNotBlocked() {
        let article = String(repeating: "Cloudflare is a CDN and security company. ", count: 100)
        XCTAssertFalse(HTMLContentParser.looksBlocked(text: article, title: "About CDNs"))
    }

    func testNormalContentIsNotBlocked() {
        XCTAssertFalse(HTMLContentParser.looksBlocked(
            text: "This is a normal article about 3D printing and drones.",
            title: "3D Printing Boom"))
    }

    // MARK: - リーダー（Jina）応答パース

    func testParseReaderResponseExtractsTitleAndContent() {
        let body = """
        Title: The Drone Boom

        URL Source: https://example.com
        Published Time: 2026-07-03

        Markdown Content:
        This is the body.
        Second paragraph.
        """
        let (title, content) = JinaReaderFetcher.parseReaderResponse(body)
        XCTAssertEqual(title, "The Drone Boom")
        XCTAssertTrue(content.hasPrefix("This is the body."))
        XCTAssertFalse(content.contains("URL Source"))
    }

    func testCleanMarkdownStripsImagesAndLinks() {
        let md = "![alt](https://img) See [the report](https://x) now. # Heading"
        let cleaned = JinaReaderFetcher.cleanMarkdown(md)
        XCTAssertFalse(cleaned.contains("https://img"))
        XCTAssertTrue(cleaned.contains("the report"))
        XCTAssertFalse(cleaned.contains("]("))
        XCTAssertTrue(cleaned.contains("Heading"))
    }

    func testDetectLanguage() {
        XCTAssertEqual(
            HTMLContentParser.detectLanguage("This is clearly an English sentence about drones."),
            "en")
    }
}
