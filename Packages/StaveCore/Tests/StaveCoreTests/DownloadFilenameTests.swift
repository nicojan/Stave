import Foundation
import Testing
@testable import StaveCore

/// Plan 3's Carried file-name fixes (plan 5 Task 14).
@Suite struct DownloadFilenameTests {
    /// A name never starts with a combining mark: it would attach to whatever the file manager or Finder draws before it.
    @Test func leadingCombiningMarkStripped() {
        #expect(DownloadFilename.sanitized("\u{301}report.pdf") == "report.pdf")
        #expect(DownloadFilename.sanitized("\u{301}\u{308}\u{20DD}x.txt") == "x.txt")
        #expect(DownloadFilename.sanitized(".\u{301}x") == "x")
        // A mark after a base letter stays: it is part of the letter.
        #expect(DownloadFilename.sanitized("e\u{301}t\u{e9}.pdf") == "e\u{301}t\u{e9}.pdf")
        #expect(DownloadFilename.sanitized("\u{301}") == "download")
    }

    /// `a.tar.gz` is numbered `a (2).tar.gz`, not `a.tar (2).gz`.
    @Test func multiDotExtensionNumbered() {
        let dir = URL(fileURLWithPath: "/private/tmp/stave-dl-test", isDirectory: true)
        let taken: Set<String> = ["a.tar.gz", "b.tar.bz2", "c.gz", "d.TAR.GZ", "e.tar"]
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        #expect(DownloadFilename.unique("a.tar.gz", in: dir, exists: exists).lastPathComponent == "a (2).tar.gz")
        #expect(DownloadFilename.unique("b.tar.bz2", in: dir, exists: exists).lastPathComponent == "b (2).tar.bz2")
        #expect(DownloadFilename.unique("c.gz", in: dir, exists: exists).lastPathComponent == "c (2).gz")
        #expect(DownloadFilename.unique("d.TAR.GZ", in: dir, exists: exists).lastPathComponent == "d (2).TAR.GZ")
        #expect(DownloadFilename.unique("e.tar", in: dir, exists: exists).lastPathComponent == "e (2).tar")
        #expect(DownloadFilename.unique("v1.2.zip", in: dir, exists: { $0.lastPathComponent == "v1.2.zip" }).lastPathComponent == "v1.2 (2).zip")
    }

    /// Invisible code points that make a name look like another one are dropped anywhere in it.
    @Test func invisibleCodePointsRemoved() {
        let invisible: [Unicode.Scalar] = ["\u{061C}", "\u{2028}", "\u{2029}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        for scalar in invisible {
            #expect(DownloadFilename.sanitized("re\(scalar)port.pdf") == "report.pdf", "U+\(String(scalar.value, radix: 16))")
            #expect(DownloadFilename.sanitized("report.pdf\(scalar)") == "report.pdf")
        }
        #expect(DownloadFilename.sanitized("\u{200B}\u{FEFF}") == "download")
    }

    /// Blank-looking characters beyond the zero-width ones: soft hyphen, combining grapheme joiner, Mongolian vowel separator, invisible
    /// math operators, Hangul fillers.
    @Test func blankLookingCodePointsRemoved() {
        let blank: [Unicode.Scalar] = ["\u{00AD}", "\u{034F}", "\u{180E}", "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}", "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}"]
        for scalar in blank {
            #expect(DownloadFilename.sanitized("re\(scalar)port.pdf") == "report.pdf", "U+\(String(scalar.value, radix: 16))")
            #expect(DownloadFilename.sanitized("\(scalar)report.pdf\(scalar)") == "report.pdf")
        }
        #expect(DownloadFilename.sanitized("\u{3164}\u{FFA0}") == "download")
    }
}
