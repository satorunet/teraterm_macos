import UIKit

/// 日本語入力 (変換の途中の文字) を受けるための UITextInput。
/// 端末は文字をためておかないので、ここで扱う「文書」は変換中の文字 (markedText) だけ。
/// 確定したら insertText で相手に送る。変換中の文字はカーソルの位置に下線付きで描く (TerminalView.draw)
final class TermTextPosition: UITextPosition {
    let offset: Int
    init(_ o: Int) { offset = o }
}
final class TermTextRange: UITextRange {
    let from: Int, to: Int
    init(_ a: Int, _ b: Int) { from = min(a, b); to = max(a, b) }
    override var start: UITextPosition { TermTextPosition(from) }
    override var end: UITextPosition { TermTextPosition(to) }
    override var isEmpty: Bool { from == to }
}

extension TerminalView: UITextInput {
    private var markedLength: Int { (markedText as NSString).length }

    // MARK: 変換中の文字

    func setMarkedText(_ text: String?, selectedRange: NSRange) {
        markedText = text ?? ""
        markedSelection = selectedRange
        setNeedsDisplay()
    }

    func unmarkText() {
        let t = markedText
        markedText = ""
        setNeedsDisplay()
        if !t.isEmpty { sendTyped(t) }
    }

    var markedTextRange: UITextRange? { markedText.isEmpty ? nil : TermTextRange(0, markedLength) }
    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { }
    }

    // MARK: 選択 (変換中の文字の中だけ)

    var selectedTextRange: UITextRange? {
        get {
            let loc = markedText.isEmpty ? 0 : min(markedLength, markedSelection.location + markedSelection.length)
            return TermTextRange(loc, loc)
        }
        set { }
    }

    func text(in range: UITextRange) -> String? {
        guard let r = range as? TermTextRange, !markedText.isEmpty else { return "" }
        let ns = markedText as NSString
        let a = max(0, min(ns.length, r.from)), b = max(a, min(ns.length, r.to))
        return ns.substring(with: NSRange(location: a, length: b - a))
    }

    func replace(_ range: UITextRange, withText text: String) {
        markedText = ""
        sendTyped(text)
    }

    // MARK: 位置

    var beginningOfDocument: UITextPosition { TermTextPosition(0) }
    var endOfDocument: UITextPosition { TermTextPosition(markedLength) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = fromPosition as? TermTextPosition, let b = toPosition as? TermTextPosition else { return nil }
        return TermTextRange(a.offset, b.offset)
    }
    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? TermTextPosition else { return nil }
        let n = p.offset + offset
        return n < 0 || n > markedLength ? nil : TermTextPosition(n)
    }
    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: return self.position(from: position, offset: -offset)
        default: return self.position(from: position, offset: offset)
        }
    }
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? TermTextPosition)?.offset ?? 0, b = (other as? TermTextPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? TermTextPosition)?.offset ?? 0) - ((from as? TermTextPosition)?.offset ?? 0)
    }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? TermTextRange else { return nil }
        return direction == .left || direction == .up ? TermTextPosition(r.from) : TermTextPosition(r.to)
    }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? TermTextPosition else { return nil }
        return direction == .left || direction == .up ? TermTextRange(0, p.offset) : TermTextRange(p.offset, markedLength)
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? { TermTextPosition(markedLength) }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: 書く向き・場所 (変換の候補をカーソルの近くに出す)

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect {
        let c = cursorCellRect
        return CGRect(x: c.minX, y: c.minY, width: max(cellW, markedTextWidth), height: c.height)
    }
    func caretRect(for position: UITextPosition) -> CGRect {
        let c = cursorCellRect
        let off = CGFloat((position as? TermTextPosition)?.offset ?? 0)
        return CGRect(x: c.minX + min(off * cellW * 2, markedTextWidth), y: c.minY, width: 2, height: c.height)
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }
}
