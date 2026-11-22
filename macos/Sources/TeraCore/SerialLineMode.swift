// シリアルポートのデータ長・パリティ・ストップビット (commlib.c CommResetSerial の DCB)。
// macOS の termios にはマーク / スペースのパリティ (CMSPAR) がないので、作れるものは別の形にして送受信のバイトを直す

import Foundation

public struct SerialLineMode: Equatable {
    /// termios に設定するデータ長 (5〜8)
    public var dataBits: Int
    /// termios に設定するパリティ: none / odd / even
    public var parity: String
    /// termios に設定するストップビット (1 / 2)
    public var stopBits: Int
    /// 送るバイトに OR / AND するもの (マーク・スペースのパリティビットを作る)
    public var outputOr: UInt8 = 0
    public var outputAnd: UInt8 = 0xFF
    /// 受けたバイトに AND するもの (パリティビットを落とす)
    public var inputAnd: UInt8 = 0xFF

    public init(dataBits: Int, parity: String, stopBits: Int) {
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
    }

    /// 作れないとき nil (8 ビット + スペースは 9 ビット目を 0 にできない)
    ///  - 7 ビット + マーク: 8N にして、8 ビット目 (パリティの位置) をいつも 1
    ///  - 7 ビット + スペース: 8N にして、8 ビット目をいつも 0
    ///  - 8 ビット + マーク: パリティの 1 はストップビットと同じなので、ストップビットを 1 つ足す (8N2)
    public static func make(dataBits: Int, parity: String, stopBits: Int) -> SerialLineMode? {
        let p = parity.lowercased()
        let d = (5...8).contains(dataBits) ? dataBits : 8
        let s = stopBits == 2 ? 2 : 1
        switch p {
        case "mark", "space":
            if d == 7 {
                var m = SerialLineMode(dataBits: 8, parity: "none", stopBits: s)
                if p == "mark" { m.outputOr = 0x80 } else { m.outputAnd = 0x7F }
                m.inputAnd = 0x7F
                return m
            }
            if d == 8 && p == "mark" { return SerialLineMode(dataBits: 8, parity: "none", stopBits: 2) }
            return nil
        case "odd", "even":
            return SerialLineMode(dataBits: d, parity: p, stopBits: s)
        default:
            return SerialLineMode(dataBits: d, parity: "none", stopBits: s)
        }
    }

    public var changesData: Bool { outputOr != 0 || outputAnd != 0xFF || inputAnd != 0xFF }

    public func transmit(_ b: [UInt8]) -> [UInt8] {
        guard outputOr != 0 || outputAnd != 0xFF else { return b }
        return b.map { ($0 | outputOr) & outputAnd }
    }

    public func receive(_ b: [UInt8]) -> [UInt8] {
        guard inputAnd != 0xFF else { return b }
        return b.map { $0 & inputAnd }
    }
}
