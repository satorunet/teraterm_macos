import Foundation

// Tera Term の TEK ウインドウ (Tektronix 4010/4014 エミュレーション)。
// ttptek/tekesc.c・tttek.c と common/tektypes.h をそのまま移したもの。
// 座標は Tera Term と同じくウインドウのピクセル (左上が原点、y は下向き)。描いたものは
// TEKDrawOp として ops に貯める (Tera Term の MemDC に描く操作)。画面に出すのは TeraMac 側

/// tektypes.h ViewSizeX / ViewSizeY (4014 の 12 ビット座標の大きさ)
public let TEKViewSizeX = 4096
public let TEKViewSizeY = 3120

public struct TEKPoint: Equatable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
}

/// 線の種類 (SetLineStyle の PS_*)
public enum TEKLineStyle: Int, Equatable {
    case solid, dot, dashDot, dash, dashDotDot
}

/// MemDC への描画 1 つ
public enum TEKDrawOp: Equatable {
    /// 背景で塗りつぶす (EscPage / TEKClearScreen / TEKResizeWindow)
    case clear
    /// MoveToEx + LineTo (終点の 1 ピクセルは描かない GDI の線)
    case line(from: TEKPoint, to: TEKPoint, color: UInt32, style: TEKLineStyle)
    /// SetPixel (同じ位置への描画)
    case pixel(TEKPoint, color: UInt32)
    /// DispChar: 1 文字。左下 (TA_LEFT | TA_BOTTOM) が at。size は文字の大きさ (0〜3)、width × height が字の枠
    case char(UInt8, at: TEKPoint, size: Int, width: Int, height: Int, color: UInt32)
    /// DrawMarker: Symbol フォントの文字 (code) を、x を中心・下端を y + markerH/2 にして描く
    case marker(UInt8, at: TEKPoint, color: UInt32)
    /// GraphText (ESC L T): 文字の幅 width・高さ height、送り幅 advance、向き angle (0:0° 1:90° 2:180° 3:270°)。at はベースライン
    case graphText([UInt8], at: TEKPoint, width: Int, height: Int, advance: Int, angle: Int, color: UInt32)
}

/// TEK ウインドウの設定 (ts の TEK まわり)
public struct TEKSettings: Equatable {
    /// AutoWinSwitch (VT<->TEK の自動切り替え)
    public var autoWinSwitch = false
    /// CRReceive == IdCRLF
    public var crReceiveCRLF = false
    /// Beep != 0
    public var beep = true
    /// TEKColor (文字・背景)。0xRRGGBB
    public var foreColor: UInt32 = 0x000000
    public var backColor: UInt32 = 0xFFFFFF
    /// TEKColorEmulation
    public var colorEmulation = false
    /// TEKGINMouseCode
    public var ginMouseCode: UInt8 = 32
    public init() {}
}

public final class TEKParser {
    // tektypes.h の IdAlphaMode など
    public enum DispMode: Int { case alpha = 0, vector, marker, plot, unknown }
    enum ParseMode { case first, escape, cs, selectCode, twoOC, gt }

    public var settings: TEKSettings

    // 画面とフォント (TEKResizeWindow で決まる)
    public private(set) var screenWidth = 0
    public private(set) var screenHeight = 0
    public private(set) var fw = [0, 0, 0, 0]
    public private(set) var fh = [0, 0, 0, 0]
    public private(set) var fontWidth = 0
    public private(set) var fontHeight = 0
    public private(set) var markerW = 0
    public private(set) var markerH = 0

    public private(set) var caretX = 0
    public private(set) var caretY = 0
    public private(set) var caretOffset = 0
    public private(set) var textSize = 0
    public private(set) var dispMode: DispMode = .alpha
    var parseMode: ParseMode = .first
    var selectCodeFlag: UInt8 = 0

    /// 色 (TextColor / PenColor は ColorIndex の値、描くときの色は memColor で決める)
    public private(set) var penColor: UInt32 = 0
    public private(set) var textColor: UInt32 = 0
    public private(set) var lineStyle: TEKLineStyle = .solid

    var moveFlag = true
    var drawing = false
    var changeEmu = false

    // GIN
    public private(set) var gin = false
    public private(set) var ginX = 0
    public private(set) var ginY = 0
    var ignoreCount = 0
    /// マウスのボタンを押している間 (ButtonDown) は受信を読まない (TEKParse が 0 を返す)
    public var holdInput = false

    // Draw
    var loXReceive = false
    var loCount = 0
    var loA: UInt8 = 0, loB: UInt8 = 0
    var hiY: UInt8 = 0, extra: UInt8 = 0, loY: UInt8 = 0, hiX: UInt8 = 0, loX: UInt8 = 0

    // 2OC
    var opCount = 0, prmCount = 0, prmCountMax = 0
    var op2OC: UInt16 = 0
    var prm2OC = [UInt16](repeating: 0, count: 17)

    // plot
    var justAfterRS = false
    var penDown = false
    var plotX = 0, plotY = 0

    // CSI
    var csBuff: [UInt8] = []

    // graph text
    public private(set) var gtWidth = 39, gtHeight = 59, gtSpacing = 12
    var gtLen = 0, gtAngle = 0
    var gtBuff: [UInt8] = []

    // marker
    public private(set) var markerType = 1
    var markerFlag = false

    /// 描いたもの (取り出すのは takeOps)
    public private(set) var ops: [TEKDrawOp] = []
    public var onBeep: (() -> Void)?
    /// 送信 (GIN の報告: CommBinaryOut)
    public var onSend: (([UInt8]) -> Void)?
    /// 画面に出した文字・改行 (FLogPutANSI)
    public var onLog: ((UInt8) -> Void)?

    // 受信バッファ (cv.InBuff) と CommInsert1Byte で戻したバイト
    private var input: [UInt8] = []
    private var inPos = 0
    private var inserted: [UInt8] = []

    public init(settings: TEKSettings = TEKSettings()) {
        self.settings = settings
        penColor = settings.foreColor
        textColor = settings.foreColor
    }

    public func takeOps() -> [TEKDrawOp] {
        let o = ops
        ops = []
        return o
    }

    private func emit(_ op: TEKDrawOp) { ops.append(op) }

    // MARK: - 画面の大きさ

    /// TEKResizeWindow で決まるフォントの大きさ。scale = FALSE (最初・フォント設定) なら標準フォントの
    /// 字の大きさ (baseFW × baseFH) から画面 (74 桁 × 35 行、縦横比は 4096:3120 以上) を決める。
    /// scale = TRUE (ユーザーが大きさを変えた) なら width × height から字の大きさを決める
    public static func layout(scale: Bool, baseFW: Int, baseFH: Int, width: Int, height: Int)
        -> (width: Int, height: Int, fw: [Int], fh: [Int]) {
        var sw = width, sh = height
        var fw0 = baseFW, fh0 = baseFH
        if scale {
            fh0 = Int(Double(sh) / 35.0)
            fw0 = Int(Double(sw) / 74.0)
        } else {
            sh = fh0 * 35
            sw = fw0 * 74
            let w = Int(Float(sh) / Float(TEKViewSizeY) * Float(TEKViewSizeX))
            if sw < w { sw = w }
        }
        let fw = [fw0, Int(Double(sw) / 80.0), Int(Double(sw) / 121.0), Int(Double(sw) / 133.0)]
        let fh = [fh0, Int(Double(sh) / 38.0), Int(Double(sh) / 58.0), Int(Double(sh) / 64.0)]
        return (sw, sh, fw, fh)
    }

    /// TEKResizeWindow: 画面を作り直す (消える)。フォントの大きさは layout の結果
    public func resize(width: Int, height: Int, fw: [Int], fh: [Int], markerW: Int? = nil, markerH: Int? = nil) {
        screenWidth = width
        screenHeight = height
        self.fw = fw
        self.fh = fh
        self.markerW = markerW ?? fw[0]
        self.markerH = markerH ?? fh[0]
        fontWidth = fw[textSize]
        fontHeight = fh[textSize]
        textColor = settings.foreColor
        penColor = settings.foreColor
        ops = [.clear]
        dispMode = .alpha
        hiY = 0; extra = 0; loY = 0; hiX = 0; loX = 0
        caretX = 0
        caretOffset = 0
        caretY = fontHeight
    }

    /// TEKSetupFont / TEKRestoreSetup: 文字の大きさを標準に戻してから作り直す
    public func resetTextSize() { textSize = 0 }

    /// TEKResetWin (ウインドウの設定を変えたとき): 色と線を初期値に戻す
    public func resetWin(oldColorEmulation: Bool) {
        textColor = settings.foreColor
        lineStyle = .solid
        penColor = settings.foreColor
        if settings.colorEmulation != oldColorEmulation { emit(.clear) }
        if settings.colorEmulation || settings.colorEmulation != oldColorEmulation { clearScreen() }
    }

    /// TEKClearScreen (編集 → 画面のクリア)
    public func clearScreen() {
        emit(.clear)
        dispMode = .alpha
        caretX = 0
        caretOffset = 0
        caretY = fontHeight
    }

    // MARK: - 受信 (TEKParse)

    /// 受信したデータを読む。VT に戻ったら (ChangeEmu = IdVT)、まだ読んでいないバイト (CommInsert1Byte で
    /// 戻したものを含む) を返す。TEK のままなら nil
    @discardableResult
    public func feed(_ bytes: [UInt8]) -> [UInt8]? {
        if inPos > 0 { input.removeFirst(inPos); inPos = 0 }
        input += bytes
        if holdInput { return nil }
        changeEmu = false
        while !changeEmu, let b = read1() {
            if ignoreCount > 0 { ignoreCount -= 1; continue }
            switch parseMode {
            case .first: parseFirst(b)
            case .escape: escape(b)
            case .cs: controlSequence(b)
            case .selectCode: selectCode(b)
            case .twoOC: twoOpCode(b)
            case .gt: graphText(b)
            }
        }
        guard changeEmu else { return nil }
        parseMode = .first
        let rest = Array(inserted.reversed()) + input[inPos...]
        inserted = []
        input = []
        inPos = 0
        return rest
    }

    private func read1() -> UInt8? {
        if let b = inserted.popLast() { return b }
        guard inPos < input.count else { return nil }
        defer { inPos += 1 }
        return input[inPos]
    }

    /// CommInsert1Byte: つぎに読むバイトとして戻す
    private func insert(_ b: UInt8) { inserted.append(b) }

    private func toVT() { changeEmu = true }

    // MARK: - tekesc.c

    private func changeTextSize() {
        fontWidth = fw[textSize]
        fontHeight = fh[textSize]
    }

    private func backSpace() {
        caretX -= fontWidth
        if caretX < 0 { caretX = 0 }
        onLog?(0x08)
    }

    private func lineFeed() {
        caretY += fontHeight
        if caretY > screenHeight {
            caretY = fontHeight
            if caretOffset == 0 || caretX < caretOffset {
                caretOffset = screenWidth >> 1
                caretX += caretOffset
                if caretX >= screenWidth { caretX = caretOffset }
            } else {
                caretX -= caretOffset
                caretOffset = 0
            }
        }
        onLog?(0x0A)
    }

    private func carriageReturn() {
        caretX = caretOffset
        onLog?(0x0D)
    }

    private func tab() {
        onLog?(0x09)
        caretX += fontWidth << 3
        if caretX >= screenWidth {
            carriageReturn()
            lineFeed()
        }
    }

    private func enterVectorMode() {
        moveFlag = true
        drawing = false
        dispMode = .vector
    }

    private func enterMarkerMode() {
        moveFlag = true
        drawing = false
        dispMode = .marker
    }

    private func enterPlotMode() {
        if dispMode == .alpha { caretOffset = 0 }
        plotX = Int(Float(caretX) / Float(screenWidth) * Float(TEKViewSizeX))
        plotY = Int(Float(screenHeight - 1 - caretY) / Float(screenHeight) * Float(TEKViewSizeY))
        dispMode = .plot
        justAfterRS = true
    }

    private func enterAlphaMode() {
        if dispMode == .vector || dispMode == .plot { caretOffset = 0 }
        dispMode = .alpha
        drawing = false
    }

    private func enterUnknownMode() {
        if dispMode == .vector || dispMode == .plot { caretOffset = 0 }
        dispMode = .unknown
    }

    /// 描くときの色 (色のエミュレーションがオフなら文字色か背景色だけ)
    private func memColor(_ c: UInt32) -> UInt32 {
        if settings.colorEmulation { return c }
        return c == settings.backColor ? settings.backColor : settings.foreColor
    }

    private func moveTo(_ x: Int, _ y: Int, draw: Bool) {
        if draw {
            if caretX == x && caretY == y {
                emit(.pixel(TEKPoint(x, y), color: memColor(penColor)))
            } else {
                emit(.line(from: TEKPoint(caretX, caretY), to: TEKPoint(x, y), color: memColor(penColor), style: lineStyle))
            }
        }
        caretX = x
        caretY = y
    }

    /// DrawMarker の文字 (Symbol フォントの文字コード)
    static func markerCode(_ type: Int) -> UInt8 {
        switch type {
        case 0: return 0xB7
        case 1: return UInt8(ascii: "+")
        case 2: return 0xC5
        case 3: return UInt8(ascii: "*")
        case 4: return UInt8(ascii: "o")
        case 5: return 0xB4
        case 6: return UInt8(ascii: "O")
        case 7: return 0xE0
        case 8: return 0xC6
        case 9: return 0xA8
        case 10: return 0xA7
        default: return UInt8(ascii: "+")
        }
    }

    private func drawMarker() {
        emit(.marker(Self.markerCode(markerType), at: TEKPoint(caretX, caretY), color: memColor(penColor)))
    }

    private func draw(_ b: UInt8) {
        if !drawing {
            loXReceive = false
            loCount = 0
            drawing = true
            if dispMode == .marker {
                moveFlag = true
                markerFlag = true
            } else {
                markerFlag = false
            }
        }
        switch b {
        case 0x00...0x1F:
            insert(b)
            return
        case 0x20...0x3F:
            if loCount == 0 { hiY = b - 0x20 } else { hiX = b - 0x20 }
        case 0x40...0x5F:
            loX = b - 0x40
            loXReceive = true
        default:
            loA = loB
            loB = b - 0x60
            loCount += 1
        }
        guard loXReceive else { return }
        drawing = false
        parseMode = .first
        if loCount > 1 { extra = loA }
        if loCount > 0 { loY = loB }
        let vx = Int(hiX) * 128 + Int(loX) * 4 + Int(extra & 3)
        let vy = Int(hiY) * 128 + Int(loY) * 4 + Int(extra / 4)
        let x = Int(Float(vx) / Float(TEKViewSizeX) * Float(screenWidth))
        let y = screenHeight - 1 - Int(Float(vy) / Float(TEKViewSizeY) * Float(screenHeight))
        moveTo(x, y, draw: !moveFlag)
        moveFlag = false
        if markerFlag { drawMarker() }
        markerFlag = false
    }

    private func plot(_ b: UInt8) {
        var x = 0, y = 0
        switch b {
        case UInt8(ascii: "A"): x = 4
        case UInt8(ascii: "B"): x = -4
        case UInt8(ascii: "D"): y = 4
        case UInt8(ascii: "E"): x = 4; y = 4
        case UInt8(ascii: "F"): x = -4; y = 4
        case UInt8(ascii: "H"): y = -4
        case UInt8(ascii: "I"): x = 4; y = -4
        case UInt8(ascii: "J"): x = -4; y = -4
        default: return
        }
        plotX = min(max(plotX + x, 0), TEKViewSizeX - 1)
        plotY = min(max(plotY + y, 0), TEKViewSizeY - 1)
        let px = Int(Float(plotX) / Float(TEKViewSizeX) * Float(screenWidth))
        let py = screenHeight - 1 - Int(Float(plotY) / Float(TEKViewSizeY) * Float(screenHeight))
        moveTo(px, py, draw: penDown)
    }

    private func dispChar(_ b: UInt8) {
        emit(.char(b, at: TEKPoint(caretX, caretY), size: textSize, width: fontWidth, height: fontHeight,
                   color: memColor(textColor)))
        caretX += fontWidth
        onLog?(b)
        if caretX > screenWidth - fontWidth {
            carriageReturn()
            lineFeed()
        }
    }

    private func beep() {
        if settings.beep { onBeep?() }
    }

    private func parseFirst(_ b: UInt8) {
        switch dispMode {
        case .alpha:
            switch b {
            case 0x07: beep()
            case 0x08: backSpace()
            case 0x09: tab()
            case 0x0A: lineFeed()
            case 0x0B, 0x0C: break
            case 0x0D:
                carriageReturn()
                if settings.crReceiveCRLF { insert(0x0A) }
            case 0x18: if settings.autoWinSwitch { toVT() }
            case 0x19, 0x1A: break
            case 0x1B: parseMode = .escape; return
            case 0x1C: enterMarkerMode()
            case 0x1D: enterVectorMode()
            case 0x1E: enterPlotMode()
            case 0x1F: break
            case 0x7F: if drawing { draw(b) }
            case 0x00...0x06, 0x0E...0x17: break
            default:
                if drawing { draw(b) } else { dispChar(b) }
            }
        case .vector, .marker:
            switch b {
            case 0x07:
                if moveFlag { moveFlag = false } else { beep() }
            case 0x0D:
                insert(0x0D)
                enterAlphaMode()
            case 0x18: if settings.autoWinSwitch { toVT() }
            case 0x19, 0x1A: break
            case 0x1B: parseMode = .escape; return
            case 0x1C: enterMarkerMode()
            case 0x1D: enterVectorMode()
            case 0x1E: enterPlotMode()
            case 0x1F: enterAlphaMode()
            case 0x00...0x06, 0x08...0x0C, 0x0E...0x17: break
            default: draw(b)
            }
        case .plot:
            switch b {
            case 0x07: beep()
            case 0x0D:
                insert(0x0D)
                enterAlphaMode()
            case 0x18: if settings.autoWinSwitch { toVT() }
            case 0x19, 0x1A: break
            case 0x1B: parseMode = .escape; return
            case 0x1C: enterMarkerMode()
            case 0x1D: enterVectorMode()
            case 0x1E: enterPlotMode()
            case 0x1F: enterAlphaMode()
            case 0x7F: break
            case 0x00...0x06, 0x08...0x0C, 0x0E...0x17: break
            default:
                if justAfterRS {
                    if b == 0x20 { penDown = false } else if b == UInt8(ascii: "P") { penDown = true } else { enterUnknownMode() }
                    justAfterRS = false
                } else {
                    plot(b)
                }
            }
        case .unknown:
            if b == 0x1F { enterAlphaMode() }
        }
        parseMode = .first
    }

    private func selectCode(_ b: UInt8) {
        switch b {
        case UInt8(ascii: " "):
            if selectCodeFlag == UInt8(ascii: "#") { selectCodeFlag = b }
            return
        case UInt8(ascii: "!"):
            if selectCodeFlag == UInt8(ascii: "%") { selectCodeFlag = b }
            return
        case UInt8(ascii: "0"): break
        case UInt8(ascii: "1"), UInt8(ascii: "2"):
            if selectCodeFlag == UInt8(ascii: " ") || selectCodeFlag == UInt8(ascii: "!") { toVT() }
        case UInt8(ascii: "3"):
            if selectCodeFlag == UInt8(ascii: "!") { toVT() }
        case UInt8(ascii: "5"):
            if selectCodeFlag == UInt8(ascii: " ") { toVT() }
        default:
            if b <= 0x1F { return }
        }
        if b >= 0x20 && b < 0x7F { parseMode = .first }
        selectCodeFlag = 0
        if !settings.autoWinSwitch { changeEmu = false }
    }

    /// ColorIndex
    static func colorIndex(fore: UInt32, back: UInt32, _ w: Int) -> UInt32 {
        switch w {
        case 1: return fore
        case 2: return 0xFF0000
        case 3: return 0x00FF00
        case 4: return 0x0000FF
        case 5: return 0x00FFFF
        case 6: return 0xFF00FF
        case 7: return 0xFFFF00
        case 8: return 0xFF8000
        case 9: return 0x80FF00
        case 10: return 0x00FF80
        case 11: return 0x0080FF
        case 12: return 0x8000FF
        case 13: return 0xFF0080
        case 14: return 0x555555
        case 15: return 0xAAAAAA
        default: return back
        }
    }

    private func setLineIndex(_ w: Int) {
        penColor = Self.colorIndex(fore: settings.foreColor, back: settings.backColor, w)
    }

    private func setTextIndex(_ w: Int) {
        textColor = Self.colorIndex(fore: settings.foreColor, back: settings.backColor, w)
    }

    private func setColorIndex(_ w: Int) {
        setLineIndex(w)
        setTextIndex(w)
    }

    private func setLineStyle(_ b: Int) {
        switch b {
        case 1: lineStyle = .dot
        case 2, 6: lineStyle = .dashDot
        case 3, 4, 7: lineStyle = .dash
        case 5, 8: lineStyle = .dashDotDot
        default: lineStyle = .solid
        }
    }

    // tektypes.h の 2 文字のコマンド
    static let idMove: UInt16 = 0x4C46, idDraw: UInt16 = 0x4C47, idDrawMarker: UInt16 = 0x4C48
    static let idGraphText: UInt16 = 0x4C54, idSetDialogVisibility: UInt16 = 0x4C56
    static let idSetGraphTextSize: UInt16 = 0x4D43, idSetWriteMode: UInt16 = 0x4D47
    static let idSetLineIndex: UInt16 = 0x4D4C, idSetMarkerType: UInt16 = 0x4D4D
    static let idSetCharPath: UInt16 = 0x4D4E, idSetPrecision: UInt16 = 0x4D51
    static let idSetRotation: UInt16 = 0x4D52, idSetTextIndex: UInt16 = 0x4D54
    static let idSetLineStyle: UInt16 = 0x4D56

    private func twoOpCode(_ b: UInt8) {
        if opCount == 2 {
            opCount -= 1
            op2OC = UInt16(b) << 8
            return
        } else if opCount == 1 {
            if b <= 0x1A { return }
            if b <= 0x1F {
                insert(b)
                parseMode = .first
                return
            }
            opCount -= 1
            op2OC = op2OC &+ UInt16(b)
            switch op2OC {
            case Self.idGraphText, Self.idSetDialogVisibility, Self.idSetWriteMode, Self.idSetLineIndex,
                 Self.idSetMarkerType, Self.idSetCharPath, Self.idSetPrecision, Self.idSetTextIndex,
                 Self.idSetLineStyle:
                prmCountMax = 1
            case Self.idSetGraphTextSize: prmCountMax = 3
            case Self.idSetRotation: prmCountMax = 2
            default: prmCountMax = 0
            }
            prm2OC = [UInt16](repeating: 0, count: 17)
            prmCount = 0
            if prmCountMax > 0 { return }
        }

        if prmCount < prmCountMax {
            if b <= 0x1A { return }
            if b <= 0x1F {
                insert(b)
                prmCount = prmCountMax
                parseMode = .first
            } else if b <= 0x2F {   // LoI (負)
                prm2OC[prmCount] = 0 &- (prm2OC[prmCount] &* 16 &+ UInt16(b - 0x20))
                prmCount += 1
            } else if b <= 0x3F {   // LoI (正)
                prm2OC[prmCount] = prm2OC[prmCount] &* 16 &+ UInt16(b - 0x30)
                prmCount += 1
            } else {
                prm2OC[prmCount] = prm2OC[prmCount] &* 64 &+ UInt16(b - 0x40)
            }
        }
        if prmCount < prmCountMax { return }

        switch op2OC {
        case Self.idMove:
            loXReceive = false; loCount = 0; drawing = true; moveFlag = true; markerFlag = false
        case Self.idDraw:
            loXReceive = false; loCount = 0; drawing = true; moveFlag = false; markerFlag = false
        case Self.idDrawMarker:
            loXReceive = false; loCount = 0; drawing = true; moveFlag = true; markerFlag = true
        case Self.idGraphText:
            gtBuff = []
            gtLen = Int(prm2OC[0])
            parseMode = gtLen > 0 ? .gt : .first
            return
        case Self.idSetGraphTextSize:
            gtWidth = Int(prm2OC[0])
            gtHeight = Int(prm2OC[1])
            gtSpacing = Int(prm2OC[2])
            if gtWidth == 0 && gtHeight == 0 && gtSpacing == 0 {
                gtWidth = 39; gtHeight = 59; gtSpacing = 12
            }
            if gtWidth <= 0 { gtWidth = 39 }
            if gtHeight <= 0 { gtWidth = 59 }   // tekesc.c のまま (GTWidth に入れている)
            if gtSpacing <= 0 { gtSpacing = 0 }
        case Self.idSetLineIndex:
            setLineIndex(Int(prm2OC[0]))
        case Self.idSetMarkerType:
            markerType = Int(prm2OC[0])
        case Self.idSetRotation:
            var re = Double(prm2OC[0]) * pow(2.0, Double(prm2OC[1]))
            re = fmod(re, 360.0)
            if re < 0 { re += 360.0 }
            if re < 45.0 { gtAngle = 0 } else if re < 135.0 { gtAngle = 1 } else if re < 315.0 { gtAngle = 2 } else { gtAngle = 3 }
        case Self.idSetTextIndex:
            setTextIndex(Int(prm2OC[0]))
        case Self.idSetLineStyle:
            setLineStyle(Int(UInt8(truncatingIfNeeded: prm2OC[0])))
        default:
            break
        }
        parseMode = .first
    }

    /// EscPage: 画面を消してアルファモードへ
    private func escPage() {
        setLineStyle(0)
        emit(.clear)
        enterAlphaMode()
        caretX = 0
        caretOffset = 0
        caretY = 0
    }

    private func escape(_ b: UInt8) {
        switch b {
        case 0x00, 0x0A, 0x0D, 0x1B, 0x7F: return
        case 0x0C: escPage()
        case 0x1A:
            gin = true
            enterAlphaMode()
        case 0x1C...0x1F:
            insert(b)
        case UInt8(ascii: "#"), UInt8(ascii: "%"):
            parseMode = .selectCode
            selectCodeFlag = b
            return
        case UInt8(ascii: "2"):
            if settings.autoWinSwitch { toVT() }
        case UInt8(ascii: "["):
            csBuff = []
            parseMode = .cs
            return
        case UInt8(ascii: "8")...UInt8(ascii: ";"):
            if textSize != Int(b) - 0x38 {
                textSize = Int(b) - 0x38
                changeTextSize()
            }
        case UInt8(ascii: "I")...UInt8(ascii: "Z"):
            parseMode = .twoOC
            opCount = 2
            twoOpCode(b)
            return
        case 0x60...0x6F:
            setLineStyle(Int((b - 0x60) & 7))
        default:
            break
        }
        parseMode = .first
    }

    private func csSetAttr(_ params: [Int]) {
        for p0 in params {
            switch max(p0, 0) {
            case 0, 37, 39: setColorIndex(1)
            case 30: setColorIndex(0)
            case 31: setColorIndex(2)
            case 32: setColorIndex(3)
            case 33: setColorIndex(7)
            case 34: setColorIndex(4)
            case 35: setColorIndex(6)
            case 36: setColorIndex(5)
            default: break   // 太字・下線・点滅・反転は何もしない
            }
        }
    }

    private func parseCS() {
        var params = [-1]
        var iCount = 0
        var firstPrm = true
        var prv: UInt8 = 0
        var b: UInt8 = 0
        var i = 0
        repeat {
            b = csBuff[i]; i += 1
            switch b {
            case 0x20...0x2F:
                if iCount < 5 { iCount += 1 }
            case 0x30...0x39:
                if params[params.count - 1] < 0 { params[params.count - 1] = 0 }
                if params[params.count - 1] < 1000 { params[params.count - 1] = params[params.count - 1] * 10 + Int(b) - 0x30 }
            case 0x3B:
                if params.count < 16 { params.append(-1) }
            case 0x3C...0x3F:
                if firstPrm { prv = b }
            default: break
            }
            firstPrm = false
        } while i < csBuff.count && !(b >= 0x40 && b <= 0x7E)

        var moveToVT = false
        if b >= 0x40 && b <= 0x7E {
            if iCount == 0 {
                switch prv {
                case 0:
                    if b == UInt8(ascii: "m") { csSetAttr(params) } else { moveToVT = true }
                case UInt8(ascii: "?"):
                    // ESC [ ? 38 h (TEK モードにする) は無視
                    if b != UInt8(ascii: "h") || params[0] != 38 { moveToVT = true }
                default:
                    moveToVT = true
                }
            } else {
                moveToVT = true
            }
        } else {
            moveToVT = true
        }

        if settings.autoWinSwitch && moveToVT {
            for c in csBuff.reversed() { insert(c) }
            insert(0x5B)
            insert(0x1B)
            toVT()
        }
        parseMode = .first
    }

    private func controlSequence(_ b: UInt8) {
        switch b {
        case 0x1B...0x1F:
            insert(b)
        default:
            if csBuff.count < 256 {
                csBuff.append(b)
                if b >= 0x40 && b <= 0x7E { parseCS() }
                return
            }
        }
        parseMode = .first
    }

    /// GraphText の文字の大きさ (ピクセル): 幅・高さ・送り幅
    public var graphTextMetrics: (width: Int, height: Int, advance: Int) {
        let w = Int(Float(gtWidth) / Float(TEKViewSizeX) * Float(screenWidth))
        let h = Int(Float(gtHeight) / Float(TEKViewSizeY) * Float(screenHeight))
        var adv = Int(Float(gtWidth + gtSpacing) / Float(TEKViewSizeX) * Float(screenWidth))
        if adv < w { adv = w }   // tmAveCharWidth (幅 w のフォント)
        return (w, h, adv)
    }

    private func graphText(_ b: UInt8) {
        switch b {
        case 0x1B...0x1F:
            insert(b)
        default:
            gtBuff.append(b)
            guard gtBuff.count >= 80 || gtBuff.count >= gtLen else { return }
            let m = graphTextMetrics
            emit(.graphText(gtBuff, at: TEKPoint(caretX, caretY), width: m.width, height: m.height,
                            advance: m.advance, angle: gtAngle, color: memColor(textColor)))
            let len = gtLen * m.advance
            switch gtAngle {
            case 0: caretX += len
            case 1: caretY -= len
            case 2: caretX -= len
            default: caretY += len
            }
        }
        parseMode = .first
    }

    // MARK: - GIN (tttek.c)

    /// TEKWMMouseMove (GIN のとき): 十字カーソルを動かす
    public func ginMove(x px: Int, y py: Int) {
        var x = px + 1, y = py + 1
        if x < 0 { x = 0 } else if x > screenWidth { x = screenWidth - 1 }
        if y < 0 { y = 0 } else if y > screenHeight { y = screenHeight - 1 }
        ginX = x
        ginY = y
    }

    /// TEKReportGIN: 押したキーと十字カーソルの位置を送る
    public func reportGIN(_ keyCode: UInt8) {
        let x = Int(Float(ginX) / Float(screenWidth) * Float(TEKViewSizeX))
        let y = Int((1.0 - Double(Float(ginY + 1) / Float(screenHeight))) * Double(TEKViewSizeY))   // C では 1.0 が double
        let code: [UInt8] = [keyCode,
                             UInt8(truncatingIfNeeded: (x >> 7) + 32), UInt8(truncatingIfNeeded: ((x >> 2) & 0x1F) + 32),
                             UInt8(truncatingIfNeeded: (y >> 7) + 32), UInt8(truncatingIfNeeded: ((y >> 2) & 0x1F) + 32),
                             0x0D]
        gin = false
        onSend?(code)
        ignoreCount = 6
    }
}
