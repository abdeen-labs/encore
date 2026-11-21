import Foundation
import PDFKit

/// Plain text from a PDF, laid out for script parsing: running headers, footers and page numbers removed,
/// blank lines where the page has a paragraph-sized vertical gap, and leading spaces that mirror each
/// line's indentation (screenplays rely on it to tell dialogue from action).
public enum PDFTextExtractor {
    public enum Failure: LocalizedError {
        case unreadable(URL)
        case locked(URL)
        case noText(URL)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let u): "“\(u.lastPathComponent)” couldn't be opened as a PDF."
            case .locked(let u): "“\(u.lastPathComponent)” is password-protected."
            case .noText(let u): "“\(u.lastPathComponent)” has no selectable text (it may be a scan)."
            }
        }
    }

    public static func text(from url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable(url) }
        if doc.isLocked { throw Failure.locked(url) }
        let text = text(from: doc)
        if text.trimmed().isEmpty { throw Failure.noText(url) }
        return text
    }

    struct Line { var text: String; var x: CGFloat; var top: CGFloat; var bottom: CGFloat; var height: CGFloat }

    public static func text(from doc: PDFDocument) -> String {
        var pages: [(lines: [Line], height: CGFloat)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            var lines: [Line] = []
            if let selection = page.selection(for: box) {
                for sel in selection.selectionsByLine() {
                    let s = (sel.string ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
                    guard !s.trimmed().isEmpty else { continue }
                    let b = sel.bounds(for: page)
                    lines.append(Line(text: s.trimmed(), x: b.minX - box.minX, top: b.maxY - box.minY,
                                      bottom: b.minY - box.minY, height: b.height))
                }
            }
            if lines.isEmpty, let s = page.string {
                // No geometry: fall back to the page's text in reading order.
                var y = box.height
                for l in s.components(separatedBy: .newlines) {
                    lines.append(Line(text: l.trimmed(), x: 0, top: y, bottom: y - 12, height: 12)); y -= 12
                }
            }
            // Top to bottom, then left to right; merge pieces that share a baseline.
            lines.sort { abs($0.top - $1.top) > 2 ? $0.top > $1.top : $0.x < $1.x }
            var merged: [Line] = []
            for l in lines {
                if var last = merged.last, abs(last.top - l.top) <= 2, abs(last.bottom - l.bottom) <= 2 {
                    last.text += " " + l.text; merged[merged.count - 1] = last
                } else { merged.append(l) }
            }
            pages.append((merged, box.height))
        }
        stripRunningHeadersAndFooters(&pages)

        let leftMargin = pages.flatMap(\.lines).map(\.x).min() ?? 0
        let charWidth: CGFloat = 7.2 // 12-pt Courier: screenplay pitch. Indentation only needs to be roughly proportional.
        var out: [String] = []
        for (pageIndex, page) in pages.enumerated() {
            let gaps = zip(page.lines, page.lines.dropFirst()).map { $0.bottom - $1.top }.filter { $0 >= 0 }.sorted()
            let typicalGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            let typicalHeight = page.lines.map(\.height).sorted().dropFirst(page.lines.count / 2).first ?? 12
            if pageIndex > 0, let prev = out.last, let first = page.lines.first {
                // Continue a sentence across the page break; otherwise start a new paragraph.
                let ends = prev.trimmed().last.map { ".!?:\"”)".contains($0) } ?? true
                if ends || first.text.first?.isUppercase == true && first.x - leftMargin > 20 { out.append("") }
            }
            for (i, line) in page.lines.enumerated() {
                if i > 0 {
                    let gap = page.lines[i - 1].bottom - line.top
                    if gap > max(typicalGap * 1.6, typicalHeight * 0.6) { out.append("") }
                }
                let indent = max(0, Int(((line.x - leftMargin) / charWidth).rounded()))
                out.append(String(repeating: " ", count: indent) + line.text)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Removes page numbers and lines repeated at the top or bottom of many pages.
    static func stripRunningHeadersAndFooters(_ pages: inout [(lines: [Line], height: CGFloat)]) {
        func key(_ s: String) -> String {
            String(s.lowercased().map { $0.isNumber ? "#" : $0 }).collapsingWhitespace()
        }
        func isPageNumber(_ s: String) -> Bool {
            let t = s.lowercased().trimmed()
            return t.range(of: #"^(page\s*)?[#]?\d{1,4}(\s*(of|/)\s*\d{1,4})?\.?$"#, options: .regularExpression) != nil
                || t.range(of: #"^[-–—]\s*\d{1,4}\s*[-–—]$"#, options: .regularExpression) != nil
                || t.range(of: #"^[ivxlc]{1,6}\.?$"#, options: .regularExpression) != nil
        }
        // Candidate lines: the two nearest each edge, within the outer 12% of the page.
        func candidates(_ page: (lines: [Line], height: CGFloat)) -> [Int] {
            let n = page.lines.count
            var c: [Int] = []
            for i in [0, 1, n - 2, n - 1] where i >= 0 && i < n && !c.contains(i) {
                let l = page.lines[i]
                if l.top >= page.height * 0.88 || l.bottom <= page.height * 0.12 { c.append(i) }
            }
            return c
        }
        var counts: [String: Int] = [:]
        for p in pages { for k in Set(candidates(p).map { key(p.lines[$0].text) }) { counts[k, default: 0] += 1 } }
        let threshold = max(2, Int((Double(pages.count) * 0.5).rounded(.up)))
        for pi in pages.indices {
            let remove = Set(candidates(pages[pi]).filter { i in
                let t = pages[pi].lines[i].text
                return isPageNumber(t) || (pages.count >= 2 && counts[key(t), default: 0] >= threshold)
            })
            pages[pi].lines = pages[pi].lines.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
        }
    }
}
