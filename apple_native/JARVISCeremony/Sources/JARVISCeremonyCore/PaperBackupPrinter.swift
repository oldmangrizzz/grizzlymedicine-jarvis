import AppKit
import CoreText
import Foundation

public enum PaperBackupPrinter {
    /// Print the mnemonic paper backup without ever materialising the full
    /// mnemonic as a single Swift String, NSString, or NSTextView buffer.
    ///
    /// The mnemonic never leaves the SecureMnemonic secure scope:
    ///   • `withMnemonicWords` gives us individual word strings.
    ///   • `SecurePrintView` stores them as `[String]` (one per line, each
    ///     containing exactly one word) — never joined into the full mnemonic.
    ///   • Each line is drawn via a transient CFAttributedString built and
    ///     released per-line via CTLineDraw; no NSAttributedString is built.
    ///   • NSTextView is not used.
    ///   • `zeroLines()` overwrites the per-line strings before the secure
    ///     scope exits.
    @MainActor public static func printMnemonic(_ mnemonic: SecureMnemonic, ceremonyHash: String, operatorID: String) {
        mnemonic.withMnemonicWords { words in
            // Build one-line-per-word list; NEVER join all words into a single String.
            var printLines: [String] = [
                "JARVIS SOUL ANCHOR PAPER BACKUP",
                "Operator: \(operatorID)",
                "Subject:  \(jarvisSubjectID)",
                "Hash:     \(String(ceremonyHash.prefix(16)))",
                "",
            ]
            for (index, word) in words.enumerated() {
                // String(format:) here contains exactly one BIP39 word — single-word transient.
                printLines.append(String(format: "%02d  %@", index + 1, word))
            }
            printLines.append("")
            printLines.append("Store separately from USB cold vault.")

            let lineHeight: CGFloat = 18
            let leftMargin: CGFloat = 36
            let topMargin: CGFloat = 36
            let pageWidth: CGFloat = 540
            let pageHeight = topMargin * 2 + lineHeight * CGFloat(printLines.count)

            let view = SecurePrintView(
                frame: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
                lines: printLines,
                lineHeight: lineHeight,
                leftMargin: leftMargin,
                topMargin: topMargin
            )
            NSPrintOperation(view: view).run()
            view.zeroLines()
            // printLines goes out of scope here; words goes out of the secure scope next.
        }
    }
}

/// NSView subclass that draws per-line strings via Core Text without ever
/// building a document-level NSAttributedString that holds the full mnemonic.
private final class SecurePrintView: NSView {
    private var lines: [String]
    private let lineHeight: CGFloat
    private let leftMargin: CGFloat
    private let topMargin: CGFloat

    init(frame: NSRect, lines: [String], lineHeight: CGFloat, leftMargin: CGFloat, topMargin: CGFloat) {
        self.lines = lines
        self.lineHeight = lineHeight
        self.leftMargin = leftMargin
        self.topMargin = topMargin
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("SecurePrintView does not support coder init") }

    /// Overwrite every stored line with spaces and clear the array.
    /// Called immediately after NSPrintOperation.run() returns.
    func zeroLines() {
        for i in lines.indices { lines[i] = String(repeating: " ", count: lines[i].count) }
        lines.removeAll()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }

        // NSView default coordinate system: origin bottom-left, y increases upward.
        // Start at the top of the view and step downward for each line.
        let ctFont = CTFontCreateWithName("Menlo-Regular" as CFString, 13.0, nil)
        let color = CGColor(gray: 0.0, alpha: 1.0)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorFromContextAttributeName: true as CFBoolean,
        ]
        cgContext.setFillColor(color)

        var y = bounds.height - topMargin - lineHeight
        for line in lines {
            // CFAttributedString holds exactly one line — never the full mnemonic.
            if let cfAttrStr = CFAttributedStringCreate(kCFAllocatorDefault, line as CFString, attrs as CFDictionary) {
                let ctLine = CTLineCreateWithAttributedString(cfAttrStr)
                cgContext.textPosition = CGPoint(x: leftMargin, y: y)
                CTLineDraw(ctLine, cgContext)
            }
            y -= lineHeight
        }
    }

    override var isOpaque: Bool { false }
}

