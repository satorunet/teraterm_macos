/// スクロールバックの行。上限に達したら一番古い行の場所に新しい行を入れる (輪のように使う)。
/// 追い出した古い行は返すので、新しい空行の入れ物として使い回せる (毎回確保・解放しない)
public struct LineBuffer: RandomAccessCollection, ExpressibleByArrayLiteral {
    private var storage: [Line] = []
    /// 論理的な先頭 (storage の何番目か)。storage.count == count
    private var start = 0

    public init() {}
    public init(_ lines: [Line]) { storage = lines }
    public init(arrayLiteral elements: Line...) { storage = elements }

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    @inline(__always) private func phys(_ i: Int) -> Int {
        let p = start + i
        return p >= storage.count ? p - storage.count : p
    }
    public subscript(i: Int) -> Line {
        get { storage[phys(i)] }
        set { storage[phys(i)] = newValue }
    }

    /// 輪を開いて start = 0 にする (めったにしない操作の前だけ)
    private mutating func normalize() {
        guard start != 0 else { return }
        storage = Array(storage[start...] + storage[..<start])
        start = 0
    }

    public mutating func append(_ l: Line) { normalize(); storage.append(l) }
    public mutating func append<S: Sequence>(contentsOf s: S) where S.Element == Line { normalize(); storage.append(contentsOf: s) }

    /// いっぱいのとき: 一番古い行と入れ替えて、追い出した行を返す
    public mutating func appendEvicting(_ l: Line) -> Line {
        precondition(!storage.isEmpty)
        let old = storage[start]
        storage[start] = l
        start += 1
        if start == storage.count { start = 0 }
        return old
    }

    /// いっぱいのとき: 一番古い行の場所をその場で書き換えて一番新しい行にする (入れ物を使い回す)
    public mutating func reuseOldest(_ body: (inout Line) -> Void) {
        precondition(!storage.isEmpty)
        body(&storage[start])
        start += 1
        if start == storage.count { start = 0 }
    }

    public mutating func removeFirst(_ n: Int) {
        precondition(n >= 0 && n <= count)
        if n == count { removeAll(); return }
        normalize()
        storage.removeFirst(n)
    }

    @discardableResult public mutating func removeLast() -> Line {
        normalize()
        return storage.removeLast()
    }

    public mutating func removeAll() { storage.removeAll(); start = 0 }

    public var array: [Line] { var c = self; c.normalize(); return c.storage }
}
