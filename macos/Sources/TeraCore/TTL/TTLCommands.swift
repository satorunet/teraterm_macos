// TTL のコマンド: 振り分け・制御構文・端末とのやりとり・ダイアログ
// ttl.cpp / ttl_gui.cpp を移したもの (Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project, BSD 3-Clause)

import Foundation
import COniguruma

enum ChecksumType { case checksum8, checksum16, checksum32, crc16, crc32 }

extension TTLInterpreter {

    // MARK: - 振り分け (ExecCmnd の switch)

    func dispatch(_ w: Rsv) -> Int {
        switch w {
        case .basename: return cmdBasename()
        case .beep: return cmdBeep()
        case .bPlusRecv: return commCmd(.bplusRecv)
        case .bPlusSend: return commCmdFile(.bplusSend)
        case .break, .continue: return cmdBreak(w)
        case .bringupBox: return cmdBringupBox()
        case .call: return cmdCall()
        case .callMenu: return commCmdInt { self.host?.ttlCallMenu($0) }
        case .changeDir: return commCmdStr { self.host?.ttlChangeDir(self.absPath($0)) }
        case .checksum8: return cmdChecksum(.checksum8)
        case .checksum8File: return cmdChecksumFile(.checksum8)
        case .checksum16: return cmdChecksum(.checksum16)
        case .checksum16File: return cmdChecksumFile(.checksum16)
        case .checksum32: return cmdChecksum(.checksum32)
        case .checksum32File: return cmdChecksumFile(.checksum32)
        case .clearScreen: return commCmdInt { self.host?.ttlClearScreen($0) }
        case .clipb2Var: return cmdClipb2Var()
        case .closeSBox: return cmdCloseSBox()
        case .closeTT: return cmdCloseTT()
        case .code2Str: return cmdCode2Str()
        case .connect, .cygConnect: return cmdConnect(w)
        case .crc16: return cmdChecksum(.crc16)
        case .crc16File: return cmdChecksumFile(.crc16)
        case .crc32: return cmdChecksum(.crc32)
        case .crc32File: return cmdChecksumFile(.crc32)
        case .delPassword: return cmdDelPassword()
        case .delPassword2: return cmdDelPassword2()
        case .delVar: return cmdDelVar()
        case .dirname: return cmdDirname()
        case .dirnameBox: return cmdDirnameBox()
        case .disconnect: return cmdDisconnect()
        case .dispStr: return cmdDispStr()
        case .do: return cmdDo()
        case .else: return cmdElse()
        case .elseIf: return cmdElseIf()
        case .enableKeyb: return commCmdBin { self.host?.ttlEnableKeyboard($0 != 0) }
        case .end: return cmdEnd()
        case .endIf: return cmdEndIf()
        case .endUntil: return cmdEndWhile(false)
        case .endWhile: return cmdEndWhile(true)
        case .exec: return cmdExec()
        case .execCmnd: return cmdExecCmnd()
        case .exit: return cmdExit()
        case .expandEnv: return cmdExpandEnv()
        case .fileClose: return cmdFileClose()
        case .fileConcat: return cmdFileConcat()
        case .fileCopy: return cmdFileCopy()
        case .fileCreate: return cmdFileCreate()
        case .fileDelete: return cmdFileDelete()
        case .fileMarkPtr: return cmdFileMarkPtr()
        case .filenameBox: return cmdFilenameBox()
        case .fileOpen: return cmdFileOpen()
        case .fileLock: return cmdFileLock()
        case .fileUnLock: return cmdFileUnLock()
        case .fileReadln: return cmdFileReadln()
        case .fileRead: return cmdFileRead()
        case .fileRename: return cmdFileRename()
        case .fileSearch: return cmdFileSearch()
        case .fileSeek: return cmdFileSeek()
        case .fileSeekBack: return cmdFileSeekBack()
        case .fileStat: return cmdFileStat()
        case .fileStrSeek: return cmdFileStrSeek()
        case .fileStrSeek2: return cmdFileStrSeek2()
        case .fileTruncate: return cmdFileTruncate()
        case .fileWrite: return cmdFileWrite(false)
        case .fileWriteLn: return cmdFileWrite(true)
        case .findClose: return cmdFindClose()
        case .findFirst: return cmdFindFirst()
        case .findNext: return cmdFindNext()
        case .flushRecv: return cmdFlushRecv()
        case .folderCreate: return cmdFolderCreate()
        case .folderDelete: return cmdFolderDelete()
        case .folderSearch: return cmdFolderSearch()
        case .for: return cmdFor()
        case .getDate, .getTime: return cmdGetTime(w)
        case .getDir: return cmdGetDir()
        case .getEnv: return cmdGetEnv()
        case .getFileAttr: return cmdGetFileAttr()
        case .getHostname: return cmdGetHostname()
        case .getIPv4Addr: return cmdGetIPv4Addr()
        case .getIPv6Addr: return cmdGetIPv6Addr()
        case .getModemStatus: return cmdGetModemStatus()
        case .getPassword: return cmdGetPassword()
        case .getPassword2: return cmdGetPassword2()
        case .setPassword: return cmdSetPassword()
        case .setPassword2: return cmdSetPassword2()
        case .isPassword: return cmdIsPassword()
        case .isPassword2: return cmdIsPassword2()
        case .getSpecialFolder: return cmdGetSpecialFolder()
        case .getTitle: return cmdGetTitle()
        case .getTTDir: return cmdGetTTDir()
        case .getTTPos: return cmdGetTTPos()
        case .getVer: return cmdGetVer()
        case .goto: return cmdGoto()
        case .ifDefined: return cmdIfDefined()
        case .if: return cmdIf()
        case .include: return cmdInclude()
        case .inputBox: return cmdInputBox(false)
        case .int2Str: return cmdInt2Str()
        case .intDim, .strDim: return cmdDim(w)
        case .kmtFinish: return commCmd(.kermitFinish)
        case .kmtGet: return commCmdFile(.kermitGet)
        case .kmtRecv: return commCmd(.kermitRecv)
        case .kmtSend: return commCmdFile(.kermitSend)
        case .listBox: return cmdListBox()
        case .loadKeyMap: return commCmdStr { self.host?.ttlLoadKeyMap(self.absPath($0)) }
        case .logAutoClose: return commCmdBin { self.host?.ttlLogAutoClose($0 != 0) }
        case .logClose: return commCmdNoArg { self.host?.ttlLogClose() }
        case .logInfo: return cmdLogInfo()
        case .logOpen: return cmdLogOpen()
        case .logPause: return commCmdNoArg { self.host?.ttlLogPause() }
        case .logRotate: return cmdLogRotate()
        case .logStart: return commCmdNoArg { self.host?.ttlLogStart() }
        case .logWrite: return commCmdStr { self.host?.ttlLogWrite($0) }
        case .loop: return cmdLoop()
        case .makePath: return cmdMakePath()
        case .messageBox: return cmdMessageBox()
        case .next: return cmdNext()
        case .passwordBox: return cmdInputBox(true)
        case .pause: return cmdPause()
        case .milliPause: return cmdMilliPause()
        case .quickVANRecv: return commCmd(.quickvanRecv)
        case .quickVANSend: return commCmdFile(.quickvanSend)
        case .random: return cmdRandom()
        case .recvLn: return cmdRecvLn()
        case .recvFile: return cmdRecvFile()
        case .reDim: return cmdReDim()
        case .regexOption: return cmdRegexOption()
        case .restoreSetup: return commCmdStr { self.host?.ttlRestoreSetup(self.absPath($0)) }
        case .return: return cmdReturn()
        case .rotateL: return cmdRotate(left: true)
        case .rotateR: return cmdRotate(left: false)
        case .scpSend: return cmdScp(send: true)
        case .scpRecv: return cmdScp(send: false)
        case .send: return cmdSend(.compat, ln: false)
        case .sendText: return cmdSend(.text, ln: false)
        case .sendBinary: return cmdSend(.binary, ln: false)
        case .sendBreak: return commCmdNoArg { self.host?.ttlSendBreak() }
        case .sendBroadcast: return cmdSendBroadcast(false)
        case .sendlnBroadcast: return cmdSendBroadcast(true)
        case .sendlnMulticast: return cmdSendMulticast(true)
        case .sendMulticast: return cmdSendMulticast(false)
        case .setMulticastName: return cmdSetMulticastName()
        case .sendFile: return cmdSendFile()
        case .sendKCode: return cmdSendKCode()
        case .sendLn: return cmdSend(.compat, ln: true)
        case .setBaud: return commCmdInt { _ = self.host?.ttlSetBaud($0) }
        case .setDate: return cmdSetDate()
        case .setDebug: return commCmdBin { self.host?.ttlSetDebug($0) }
        case .setDir: return cmdSetDir()
        case .setDlgPos: return cmdSetDlgPos()
        case .setDtr: return commCmdInt { self.host?.ttlSetDTR($0 != 0) }
        case .setEcho: return commCmdBin { self.host?.ttlSetEcho($0 != 0) }
        case .setEnv: return cmdSetEnv()
        case .setExitCode: return cmdSetExitCode()
        case .setFileAttr: return cmdSetFileAttr()
        case .setFlowCtrl: return commCmdInt { _ = self.host?.ttlSetFlowCtrl($0) }
        case .setRts: return commCmdInt { self.host?.ttlSetRTS($0 != 0) }
        case .setSerialDelayChar: return commCmdIntResult { self.host?.ttlSetSerialDelay(char: $0, line: nil) ?? false }
        case .setSerialDelayLine: return commCmdIntResult { self.host?.ttlSetSerialDelay(char: nil, line: $0) ?? false }
        case .setSync: return cmdSetSync()
        case .setTime: return cmdSetTime()
        case .setTitle: return commCmdStr { self.host?.ttlSetTitle($0.u8) }
        case .show: return cmdShow()
        case .showTT: return commCmdInt { self.host?.ttlShowTT($0) }
        case .sprintf: return cmdSprintf(false)
        case .sprintf2: return cmdSprintf(true)
        case .statusBox: return cmdStatusBox()
        case .str2Code: return cmdStr2Code()
        case .str2Int: return cmdStr2Int()
        case .strCompare: return cmdStrCompare()
        case .strConcat: return cmdStrConcat()
        case .strCopy: return cmdStrCopy()
        case .strInsert: return cmdStrInsert()
        case .strJoin: return cmdStrJoin()
        case .strLen: return cmdStrLen()
        case .strMatch: return cmdStrMatch()
        case .strRemove: return cmdStrRemove()
        case .strReplace: return cmdStrReplace()
        case .strScan: return cmdStrScan()
        case .strSpecial: return cmdStrSpecial()
        case .strSplit: return cmdStrSplit()
        case .strTrim: return cmdStrTrim()
        case .testLink: return cmdTestLink()
        case .toLower: return cmdToLower()
        case .toUpper: return cmdToUpper()
        case .unlink: return cmdUnlink()
        case .uptime: return cmdUptime()
        case .var2Clipb: return cmdVar2Clipb()
        case .wait: return cmdWait(false)
        case .wait4all: return cmdWait4all()
        case .waitEvent: return cmdWaitEvent()
        case .waitLn: return cmdWait(true)
        case .waitN: return cmdWaitN()
        case .waitRecv: return cmdWaitRecv()
        case .waitRegex: return cmdWaitRegex()
        case .while: return cmdWhile(true)
        case .until: return cmdWhile(false)
        case .xmodemRecv: return cmdXmodemRecv()
        case .xmodemSend: return cmdXmodemSend()
        case .yesNoBox: return cmdYesNoBox()
        case .zmodemRecv: return commCmd(.zmodemRecv)
        case .zmodemSend: return cmdZmodemSend()
        case .ymodemRecv: return commCmd(.ymodemRecv)
        case .ymodemSend: return cmdYmodemSend()
        default: return E.syntax
        }
    }

    /// メインスレッドで端末の操作をする (ホストは自分でメインスレッドに移す)
    var h: TTLHost? { host }

    // MARK: - 端末に頼むだけのコマンド (TTLCommCmd*)

    func commCmdNoArg(_ f: () -> Void) -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if !linked { return E.linkFirst }
        f()
        return 0
    }

    /// 引数なしでファイル転送など (結果を result に)
    func commCmd(_ kind: TTLTransfer) -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if !linked { return E.linkFirst }
        if let r = host?.ttlTransfer(kind, files: [], option: 0) { setResult(r) }
        return 0
    }

    func commCmdFile(_ kind: TTLTransfer) -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        if let r = host?.ttlTransfer(kind, files: [absPath(s)], option: 0) { setResult(r) }
        return 0
    }

    func commCmdStr(_ f: ([UInt8]) -> Void) -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        f(s)
        return 0
    }

    func commCmdBin(_ f: (Int) -> Void) -> Int {
        var err = 0
        let v = getIntVal(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        f(v)
        return 0
    }

    func commCmdInt(_ f: (Int) -> Void) -> Int { commCmdBin(f) }

    /// 結果を result に入れるもの (setbaud など)
    func commCmdIntResult(_ f: (Int) -> Bool) -> Int {
        var err = 0
        let v = getIntVal(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        setResult(f(v) ? 1 : 0)
        return 0
    }

    // MARK: - 制御構文

    func cmdBreak(_ w: Rsv) -> Int {
        if getFirstChar() != 0 { return E.syntax }
        return breakLoop(w)
    }

    func cmdCall() -> Int {
        guard let lab = getLabelName(), getFirstChar() == 0 else { return E.syntax }
        if let (t, id) = checkVar(lab), t == .label { return callToLabel(id) }
        return E.labelReq
    }

    func cmdGoto() -> Int {
        guard let lab = getLabelName(), getFirstChar() == 0 else { return E.syntax }
        if let (t, id) = checkVar(lab), t == .label { jumpToLabel(id); return 0 }
        return E.labelReq
    }

    func cmdReturn() -> Int {
        if getFirstChar() == 0 { return returnFromSub() }
        return E.syntax
    }

    func cmdDo() -> Int {
        var err = 0
        var val: Int32 = 1
        if checkParameterGiven() {
            if let w = getReservedWord() {
                switch w {
                case .while: getIntVal(&val, &err)
                case .until: getIntVal(&val, &err); val = val == 0 ? 1 : 0
                default: err = E.syntax
                }
                endOfLine(&err)
            } else {
                err = E.syntax
            }
        }
        if err != 0 { return err }
        if val != 0 { return setWhileLoop() }
        endWhileLoop()
        return 0
    }

    func cmdLoop() -> Int {
        var err = 0
        var val: Int32 = 1
        if checkParameterGiven() {
            if let w = getReservedWord() {
                switch w {
                case .while: getIntVal(&val, &err)
                case .until: getIntVal(&val, &err); val = val == 0 ? 1 : 0
                default: err = E.syntax
                }
                endOfLine(&err)
            } else {
                err = E.syntax
            }
        }
        if err != 0 { return err }
        return backToWhile(val != 0)
    }

    func cmdWhile(_ mode: Bool) -> Int {
        var err = 0
        var val: Int32 = mode ? 1 : 0
        if checkParameterGiven() { getIntVal(&val, &err) }
        endOfLine(&err)
        if err != 0 { return err }
        if (val != 0) == mode { return setWhileLoop() }
        endWhileLoop()
        return 0
    }

    func cmdEndWhile(_ mode: Bool) -> Int {
        var err = 0
        var val: Int32 = mode ? 1 : 0
        if checkParameterGiven() { getIntVal(&val, &err) }
        endOfLine(&err)
        if err != 0 { return err }
        return backToWhile((val != 0) == mode)
    }

    func cmdFor() -> Int {
        var err = 0
        let id = getIntVar(&err)
        var vs: Int32 = 0, ve: Int32 = 0
        getIntVal(&vs, &err)
        getIntVal(&ve, &err)
        endOfLine(&err)
        if err != 0 { return err }
        if !checkNext() {
            err = setForLoop()
            if err == 0 {
                setIntVal(id, vs)
                if copyIntVal(id) == ve { lastForLoop() }
            }
        } else {
            var i = copyIntVal(id)
            if i < ve { i += 1 } else if i > ve { i -= 1 }
            setIntVal(id, i)
            if i == ve { lastForLoop() }
        }
        return err
    }

    func cmdNext() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        return nextLoop()
    }

    func cmdIf() -> Int {
        var err = 0
        var t = VType.unknown
        var val: Int32 = 0
        if !getExpression(&t, &val, &err) { return E.syntax }
        if err != 0 { return err }
        if t != .integer { return E.typeMismatch }
        let tmp = linePtr
        if getReservedWord() == .then {
            if getFirstChar() != 0 { return E.syntax }
            ifNest += 1
            if val == 0 { elseFlag = 1 }
        } else {
            linePtr = tmp
            if !checkParameterGiven() { return E.syntax }
            if val == 0 { return 0 }
            return execCmnd()
        }
        return err
    }

    func cmdElse() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if ifNest < 1 { return E.invalidCtl }
        ifNest -= 1
        endIfFlag = 1
        return 0
    }

    func cmdElseIf() -> Int {
        var err = 0
        _ = checkElseIf(&err)
        if err != 0 { return err }
        if ifNest < 1 { return E.invalidCtl }
        ifNest -= 1
        endIfFlag = 1
        return 0
    }

    func cmdEndIf() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if ifNest < 1 { return E.invalidCtl }
        ifNest -= 1
        return 0
    }

    func cmdEnd() -> Int {
        if getFirstChar() == 0 { status = .end; return 0 }
        return E.syntax
    }

    func cmdExit() -> Int {
        if getFirstChar() == 0 {
            if !exitBuffer() { status = .end }
            return 0
        }
        return E.syntax
    }

    func cmdInclude() -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err != 0 { return err }
        if s.isEmpty { return E.cantOpen }
        if !buffInclude(absPath(s)) { return E.cantOpen }
        return 0
    }

    func cmdExecCmnd() -> Int {
        var err = 0
        let next = getStrVal(&err)
        if err != 0 { return err }
        if getFirstChar() != 0 { return E.syntax }
        lineBuff = Array(next.prefix(MaxLineLen - 1))
        linePtr = 0
        let b = getFirstChar()
        linePtr -= 1
        parseAgain = b != 0 && b != 0x3A && b != 0x3B
        return 0
    }

    func cmdIfDefined() -> Int {
        var err = 0
        let t = getVarType(&err)
        setResult(t.rawValue)
        return err
    }

    func cmdDim(_ w: Rsv) -> Int {
        var err = 0
        guard let name = getIdentifier() else { return E.syntax }
        if checkReservedWord(name) != nil { return E.syntax }
        if checkVar(name) != nil { return E.syntax }
        let size = getIntVal(&err)
        if err != 0 { return err }
        return w == .intDim ? newIntAryVar(name, size) : newStrAryVar(name, size)
    }

    func cmdReDim() -> Int {
        var err = 0
        guard let name = getIdentifier() else { return E.syntax }
        if isSystemVariable(name) { return E.syntax }
        if checkReservedWord(name) != nil { return E.syntax }
        guard let (t, id) = checkVar(name) else { return E.varNotInit }
        if t != .intArray && t != .strArray { return E.typeMismatch }
        let size = getIntVal(&err)
        if err != 0 { return err }
        if size < 1 || size > 65536 { return E.outOfRange }
        var preserve = false
        let s = getStrVal(&err)
        if err == 0 {
            if s.isEmpty { preserve = false } else if s.u8.lowercased() == "preserve" { preserve = true } else { return E.syntax }
        } else if err == E.syntax {
            preserve = false
        } else {
            return err
        }
        return reDim(id, size, preserve)
    }

    func cmdDelVar() -> Int {
        guard var name = getIdentifier() else { return E.syntax }
        while true {
            if isSystemVariable(name) { return E.syntax }
            if checkReservedWord(name) != nil { return E.syntax }
            guard let (t, id) = checkVar(name) else { return E.varNotInit }
            if t == .unknown || t == .label { return E.syntax }
            let e = delVar(id)
            if e != 0 { return e }
            guard let n = getIdentifier() else { break }
            name = n
        }
        return 0
    }

    // MARK: - 待つ

    func cmdPause() -> Int {
        var err = 0
        let t = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if t > 0 {
            status = .pause
            timeLimit = Double(t)
            timeStart = Date()
            timerOn = true
        }
        return 0
    }

    func cmdMilliPause() -> Int {
        var err = 0
        let t = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        if t > 0 { sleep(Double(t) / 1000) }
        return 0
    }

    func cmdWait(_ ln: Bool) -> Int {
        recv.lock(); defer { recv.unlock() }
        clearWait()
        var err = 0
        var i = 0
        while i < 10 {
            err = 0
            if let s = getString(&err) {
                setWait(i + 1, s)
            } else {
                var t = VType.unknown, v: Int32 = 0
                if getExpression(&t, &v, &err) && err == 0 {
                    if t == .string { setWait(i + 1, ttlTrunc(strVarPtr(Int(v)))) } else { err = E.typeMismatch }
                } else {
                    break
                }
            }
            if err != 0 { break }
            i += 1
        }
        endOfLine(&err)
        if !linked { err = E.linkFirst }
        if err == 0 && i > 0 {
            status = ln ? .waitLn : .wait
            startTimer()
        } else {
            clearWait()
        }
        return err
    }

    func cmdWait4all() -> Int {
        let e = cmdWait(false)
        if status == .wait { status = .wait4all }
        return e
    }

    func cmdWaitRegex() -> Int {
        let e = cmdWait(false)
        recv.lock()
        regexWait = true
        recv.unlock()
        return e
    }

    func cmdRecvLn() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if !linked { return E.linkFirst }
        recv.lock(); defer { recv.unlock() }
        clearWait()
        setWait(1, [0x0A])
        setInputStr([])
        setResult(1)
        status = .waitNL
        startTimer()
        return 0
    }

    func cmdWaitEvent() -> Int {
        var err = 0
        let c = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        wakeupCondition = c & 15
        startTimer()
        status = .sleep
        return 0
    }

    func cmdWaitN() -> Int {
        recv.lock(); defer { recv.unlock() }
        clearWaitN()
        var err = 0
        let n = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        setWaitN(n)
        if !linked { return E.linkFirst }
        status = .waitN
        startTimer()
        return 0
    }

    func cmdWaitRecv() -> Int {
        var err = 0
        let s = getStrVal(&err)
        let len = getIntVal(&err)
        let pos = getIntVal(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        recv.lock(); defer { recv.unlock() }
        setInputStr([])
        setWait2(s, len, pos)
        status = .wait2
        startTimer()
        return 0
    }

    func cmdFlushRecv() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if !linked { return E.linkFirst }
        flushRecv()
        return 0
    }

    func cmdSetSync() -> Int {
        var err = 0
        let v = getIntVal(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        recv.lock(); syncMode = v != 0; recv.unlock()
        return 0
    }

    func cmdRegexOption() -> Int {
        var err = 0
        var optNone = false
        var newOpt: OnigOptionType = 0
        var newEnc: OnigEncoding?
        var newSyntax: UnsafeMutablePointer<OnigSyntaxType>?
        while checkParameterGiven() {
            let s = getStrVal(&err).u8
            if err != 0 { return err }
            let u = s.uppercased()
            let encName = u.hasPrefix("ENCODING_") ? String(u.dropFirst(9)) : u
            if let e = teramac_onig_encoding(encName) {
                if newEnc != nil { return E.syntax }
                newEnc = e
            } else if u == "SYNTAX_DEFAULT" {
                if newSyntax != nil { return E.syntax }
                newSyntax = teramac_onig_syntax("DEFAULT")
            } else if u != "DEFAULT", let sy = teramac_onig_syntax(u.hasPrefix("SYNTAX_") ? String(u.dropFirst(7)) : u) {
                if newSyntax != nil { return E.syntax }
                newSyntax = sy
            } else if u == "OPTION_NONE" {
                if newOpt != 0 || optNone { return E.syntax }
                optNone = true
            } else if let o = TTLRegex.optionNames[u.hasPrefix("OPTION_") ? String(u.dropFirst(7)) : u] {
                if optNone { return E.syntax }
                newOpt |= o
            } else {
                return E.syntax
            }
        }
        if let e = newEnc { regexEnc = e }
        if let sy = newSyntax { regexSyntax = sy }
        if newOpt != 0 || optNone { regexOpt = newOpt }
        return 0
    }

    // MARK: - 送信

    /// send の引数を全部つなげる (GetParamStrings)
    func getParamStrings(_ out: inout [UInt8]) -> Int {
        var err = 0
        while true {
            if let s = getString(&err) {
                if err != 0 { return err }
                out += s
            } else {
                var t = VType.unknown, v: Int32 = 0
                if getExpression(&t, &v, &err) {
                    if err != 0 { return err }
                    switch t {
                    case .integer: out.append(UInt8(truncatingIfNeeded: v))
                    case .string: out += strVarPtr(Int(v))
                    default: return E.typeMismatch
                    }
                } else {
                    break
                }
            }
        }
        return 0
    }

    func cmdSend(_ mode: TTLSendMode, ln: Bool) -> Int {
        if !linked { return E.linkFirst }
        var buf: [UInt8] = []
        let r = getParamStrings(&buf)
        if r != 0 { return r }
        if ln { buf.append(0x0D) }
        host?.ttlSend(buf, mode: mode)
        return 0
    }

    func getBroadcastString(_ crlf: Bool, _ out: inout [UInt8]) -> Int {
        let r = getParamStrings(&out)
        if r != 0 { return r }
        out = Array(out.prefix(MaxStrLen - 1))
        if crlf { out += [0x0D, 0x0A] }
        return 0
    }

    func cmdSendBroadcast(_ crlf: Bool) -> Int {
        if !linked { return E.linkFirst }
        var buf: [UInt8] = []
        let r = getBroadcastString(crlf, &buf)
        if r != 0 { return r }
        host?.ttlSendBroadcast(buf, multicastName: nil)
        return 0
    }

    func cmdSetMulticastName() -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err != 0 { return err }
        multicastName = s.u8
        host?.ttlSetMulticastName(multicastName)
        return 0
    }

    func cmdSendMulticast(_ crlf: Bool) -> Int {
        if !linked { return E.linkFirst }
        var err = 0
        let name = getStrVal(&err)
        if err != 0 { return err }
        var buf: [UInt8] = []
        let r = getBroadcastString(crlf, &buf)
        if r != 0 { return r }
        host?.ttlSendBroadcast(buf, multicastName: name.u8)
        return 0
    }

    func cmdSendFile() -> Int {
        var err = 0
        let s = getStrVal(&err)
        let bin = getIntVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        _ = host?.ttlSendFile(absPath(s), binary: bin != 0)
        return 0
    }

    func cmdRecvFile() -> Int {
        var err = 0
        let s = getStrVal(&err)
        _ = getIntVal(&err)
        var stop = getIntVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        if stop < 0 { stop = 0 }
        setResult((host?.ttlRecvFile(absPath(s), binary: true, autoStopSec: stop) ?? false) ? 1 : 0)
        return 0
    }

    func cmdSendKCode() -> Int {
        var err = 0
        let code = getIntVal(&err)
        let count = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        host?.ttlSendKCode(code & 0xFFFF, count: count & 0xFFFF)
        return 0
    }

    func cmdDispStr() -> Int {
        if !linked { return E.linkFirst }
        var buf: [UInt8] = []
        var err = 0
        while true {
            if let s = getString(&err) {
                if err != 0 { return err }
                buf += s
            } else {
                var t = VType.unknown, v: Int32 = 0
                if getExpression(&t, &v, &err) {
                    if err != 0 { return err }
                    switch t {
                    case .integer: buf.append(UInt8(truncatingIfNeeded: v))
                    case .string: buf += strVarPtr(Int(v))
                    default: return E.typeMismatch
                    }
                } else {
                    break
                }
            }
            buf = Array(buf.prefix(MaxStrLen - 1))
        }
        host?.ttlDispStr(buf)
        return 0
    }

    // MARK: - 接続

    func cmdConnect(_ w: Rsv) -> Int {
        var err = 0
        var s: [UInt8] = []
        if w == .connect || checkParameterGiven() {
            s = getStrVal(&err)
            if err != 0 { return err }
        }
        if getFirstChar() != 0 { return E.syntax }
        recv.lock()
        let ready = comReady, isLinked = linked
        recv.unlock()
        guard let host = host else { setResult(0); return 0 }
        if !isLinked {
            // unlink / closett のあと: Tera Term と同じく新しいウインドウを開いてつなぐ
            setResult(0)
            guard host.ttlLinkNewWindow() else { return E.cantConnect }
            recv.lock()
            linked = true
            comReady = false
            ringStart = 0; ringCount = 0
            recv.unlock()
        } else if ready {
            setResult(2)
            return 0
        }
        // 接続し終わる (または失敗する) まで待つ
        if host.ttlConnect(s.u8, cygwin: w == .cygConnect) {
            // つながるまで待つ (ホストに聞くときは受信のロックを持たない: メインスレッドと取り合わないように)
            let deadline = Date(timeIntervalSinceNow: 30)
            func ready() -> Bool { recv.lock(); defer { recv.unlock() }; return comReady || _cancelled }
            while !ready() && Date() < deadline && host.ttlIsConnecting() { Thread.sleep(forTimeInterval: 0.1) }
            recv.lock()
            let ok = comReady
            recv.unlock()
            setResult(ok ? 2 : 1)
        } else {
            setResult(1)
        }
        return 0
    }

    func cmdDisconnect() -> Int {
        var err = 0
        var v = 1
        if checkParameterGiven() { v = getIntVal(&err) }
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        host?.ttlDisconnect(confirm: v != 0)
        return 0
    }

    func cmdCloseTT() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        if !linked { return E.linkFirst }
        host?.ttlCloseTT()
        recv.lock()
        linked = false
        comReady = false
        recv.unlock()
        return 0
    }

    func cmdTestLink() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        recv.lock()
        let r = !linked ? 0 : (comReady ? 2 : 1)
        recv.unlock()
        setResult(r)
        return 0
    }

    func cmdUnlink() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        recv.lock()
        linked = false
        recv.unlock()
        return 0
    }

    // MARK: - 端末の情報

    func cmdGetTitle() -> Int {
        var err = 0
        let id = getStrVar(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        setStrVal(id, (host?.ttlGetTitle() ?? "").ttl)
        return 0
    }

    func cmdGetHostname() -> Int {
        var err = 0
        let id = getStrVar(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        setStrVal(id, (host?.ttlGetHostname() ?? "").ttl)
        return 0
    }

    func cmdGetModemStatus() -> Int {
        var err = 0
        let id = getIntVar(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        if let v = host?.ttlGetModemStatus() {
            setIntVal(id, Int32(v))
            setResult(0)
        } else {
            setResult(1)
        }
        return 0
    }

    func cmdGetTTPos() -> Int {
        var err = 0
        var ids: [Int] = []
        for _ in 0..<9 { ids.append(getIntVar(&err)) }
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        if let v = host?.ttlGetTTPos(), v.count == 9 {
            for (i, id) in ids.enumerated() { setIntVal(id, Int32(truncatingIfNeeded: v[i])) }
            setResult(0)
        } else {
            setResult(-1)
        }
        return 0
    }

    // MARK: - ログ

    func cmdLogOpen() -> Int {
        var err = 0
        let s = getStrVal(&err)
        var o = TTLLogOptions()
        o.binary = getIntVal(&err) != 0
        o.append = getIntVal(&err) != 0
        if err != 0 { return err }
        if checkParameterGiven() {
            o.plainText = getIntVal(&err) != 0
            if err != 0 { return err }
            if checkParameterGiven() {
                o.timestamp = getIntVal(&err) != 0
                if err != 0 { return err }
                if checkParameterGiven() {
                    o.hideDialog = getIntVal(&err) != 0
                    if err != 0 { return err }
                    if checkParameterGiven() {
                        o.includeScreenBuffer = getIntVal(&err) != 0
                        if err != 0 { return err }
                        if checkParameterGiven() {
                            let t = getIntVal(&err)
                            if err != 0 { return err }
                            if t < 0 || t > 3 { return E.syntax }
                            o.timestampType = t
                        }
                    }
                }
            }
        }
        if s.isEmpty || getFirstChar() != 0 { return E.syntax }
        let ok = host?.ttlLogOpen(absPath(s), options: o) ?? false
        setResult(ok ? 0 : 1)
        return 0
    }

    func cmdLogInfo() -> Int {
        var err = 0
        let id = getStrVar(&err)
        endOfLine(&err)
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        if let p = host?.ttlLogInfo() {
            setResult(1)
            setStrVal(id, p.ttl)
        } else {
            setResult(0)
            setStrVal(id, [])
        }
        return 0
    }

    func cmdLogRotate() -> Int {
        var err = 0
        let s = getStrVal(&err).u8
        if err == 0 && !linked { err = E.linkFirst }
        if err != 0 { return err }
        err = E.syntax
        var command = ""
        if s == "size" {
            if checkParameterGiven() {
                err = 0
                var str2 = getStrVal(&err).u8
                var size = 0
                if err == 0, let last = str2.last {
                    var num = 1
                    if last.isNumber { num = 1 }
                    else if last == "K" { str2.removeLast(); num = 1024 }
                    else if last == "M" { str2.removeLast(); num = 1024 * 1024 }
                    else { err = E.syntax }
                    size = (Int(str2.trimmingCharacters(in: .whitespaces)) ?? 0) * num
                }
                if size < 128 { err = E.syntax }
                if err == 0 { command = "size \(size)" }
            }
        } else if s == "rotate" {
            if checkParameterGiven() {
                err = 0
                let n = getIntVal(&err)
                if n <= 0 { err = E.syntax }
                if err == 0 { command = "rotate \(n)" }
            }
        } else if s == "halt" {
            err = 0
            command = "halt"
        }
        if err != 0 { return err }
        host?.ttlLogRotate(command)
        return 0
    }

    // MARK: - ファイル転送

    func cmdXmodemRecv() -> Int {
        var err = 0
        let s = getStrVal(&err)
        let bin = getIntVal(&err)
        var opt = getIntVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        // XoptCheck=1 XoptCRC=2 Xopt1kCRC=3 (1kCRC は受信では CRC と同じ)
        switch opt {
        case 2: break
        case 3: opt = 2
        default: opt = 1
        }
        if let r = host?.ttlTransfer(.xmodemRecv, files: [absPath(s)], option: opt | (bin != 0 ? 0x100 : 0)) { setResult(r) }
        return 0
    }

    func cmdXmodemSend() -> Int {
        var err = 0
        let s = getStrVal(&err)
        var opt = getIntVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        if opt != 3 { opt = 2 }
        if let r = host?.ttlTransfer(.xmodemSend, files: [absPath(s)], option: opt) { setResult(r) }
        return 0
    }

    func cmdZmodemSend() -> Int {
        var err = 0
        let s = getStrVal(&err)
        let bin = getIntVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        if let r = host?.ttlTransfer(.zmodemSend, files: [absPath(s)], option: bin) { setResult(r) }
        return 0
    }

    func cmdYmodemSend() -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err == 0 && (s.isEmpty || getFirstChar() != 0) { err = E.syntax }
        if err != 0 { return err }
        if let r = host?.ttlTransfer(.ymodemSend, files: [absPath(s)], option: 0) { setResult(r) }
        return 0
    }

    func cmdScp(send: Bool) -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err == 0 && s.isEmpty { err = E.syntax }
        if err != 0 { return err }
        var s2 = getStrVal(&err)
        if err != 0 { s2 = []; err = 0 }
        if getFirstChar() != 0 { return E.syntax }
        if send {
            _ = host?.ttlScp(send: true, from: absPath(s), to: s2.u8)
        } else {
            _ = host?.ttlScp(send: false, from: s.u8, to: s2.isEmpty ? "" : absPath(s2))
        }
        return 0
    }

    // MARK: - ダイアログ (ttl_gui.cpp)

    /// \n などを制御文字にする (ttlib.c の RestoreNewLine と同じ: \\ \n \t \0 だけ)
    func restoreNewLine(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < s.count {
            if s[i] == 0x5C {
                let n: UInt8 = i + 1 < s.count ? s[i + 1] : 0
                switch n {
                case 0x5C: out.append(0x5C); i += 1
                case 0x6E: out.append(0x0A); i += 1
                case 0x74: out.append(0x09); i += 1
                case 0x30: return out   // \0 で文字列が終わる
                default: out.append(0x5C)
                }
            } else {
                out.append(s[i])
            }
            i += 1
        }
        return out
    }

    enum BoxKind { case msg, yesNo, status, list }

    func messageCommand(_ kind: BoxKind, _ err: inout Int) -> Int {
        err = 0
        var s1 = getStrVal2(&err, autoConversion: true)
        let s2 = getStrVal2(&err, autoConversion: true)
        if err != 0 { return 0 }
        var sp = 0
        if kind != .list {
            if checkParameterGiven() { sp = getIntVal(&err) }
            endOfLine(&err)
            if err != 0 { return 0 }
        }
        if sp != 0 { s1 = restoreNewLine(s1) }
        switch kind {
        case .msg:
            if host?.ttlMessageBox(s1.u8, title: s2.u8) == false { status = .end }
        case .yesNo:
            let r = host?.ttlYesNoBox(s1.u8, title: s2.u8) ?? 0
            if r < 0 { status = .end }
            return r
        case .status:
            host?.ttlStatusBox(s1.u8, title: s2.u8)
        case .list:
            let id = getAryVar(.strArray, &err)
            var sel = 0
            var opts = TTLListBoxOptions()
            while checkParameterGiven() {
                let t = getStrVal2(&err, autoConversion: true).u8
                if err != 0 { break }
                let l = t.lowercased()
                if l == "dblclick=on" { opts.doubleClick = true }
                else if l == "minmaxbutton=on" { opts.minMaxButton = true }
                else if l == "minimize=on" { opts.minimize = true; opts.maximize = false }
                else if l == "maximize=on" { opts.minimize = false; opts.maximize = true }
                else if l.hasPrefix("listboxsize=") {
                    let parts = l.dropFirst("listboxsize=".count).split(whereSeparator: { $0 == "x" })
                    if parts.count == 2, let w = Int(parts[0]), let hh = Int(parts[1]), w >= 0, hh >= 0 { opts.size = (w, hh) } else { err = E.syntax; break }
                } else if let n = Int(t.trimmingCharacters(in: .whitespaces)) {
                    sel = n
                } else {
                    err = E.syntax; break
                }
            }
            endOfLine(&err)
            if err != 0 { return 0 }
            let items = vars[id].strAry.map { ($0 ?? []).u8 }
            if items.isEmpty || vars[id].strAry[0] == nil { err = E.syntax; return -1 }
            if sel < 0 || sel >= items.count { sel = 0 }
            let r = host?.ttlListBox(s1.u8, title: s2.u8, items: items, selected: sel, options: opts) ?? -1
            if r == -2 { status = .end }
            return r
        }
        return 0
    }

    func cmdMessageBox() -> Int {
        var err = 0
        _ = messageCommand(.msg, &err)
        return err
    }

    func cmdStatusBox() -> Int {
        var err = 0
        _ = messageCommand(.status, &err)
        return err
    }

    func cmdYesNoBox() -> Int {
        var err = 0
        let r = messageCommand(.yesNo, &err)
        if err != 0 { return err }
        setResult(r == 1 ? 1 : 0)
        return 0
    }

    func cmdListBox() -> Int {
        var err = 0
        let r = messageCommand(.list, &err)
        setResult(r)
        return err
    }

    func cmdCloseSBox() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        host?.ttlCloseStatus()
        return 0
    }

    func cmdBringupBox() -> Int {
        if getFirstChar() != 0 { return E.syntax }
        host?.ttlBringupBox()
        return 0
    }

    func cmdSetDlgPos() -> Int {
        var err = 0
        if checkParameterGiven() {
            let x = getIntVal(&err)
            let y = getIntVal(&err)
            var position: Int?
            if checkParameterGiven() {
                let p = getIntVal(&err)
                if p < 1 || p > 10 { err = E.syntax }
                position = p
                if checkParameterGiven() { _ = getIntVal(&err); _ = getIntVal(&err) }
            }
            endOfLine(&err)
            if err != 0 { return err }
            host?.ttlSetDialogPos(x: x, y: y, position: position)
        } else {
            host?.ttlSetDialogPos(x: Int.min, y: Int.min, position: nil)
        }
        return 0
    }

    func cmdShow() -> Int {
        var err = 0
        let v = getIntVal(&err)
        endOfLine(&err)
        if err != 0 { return err }
        host?.ttlShowMacroWindow(v)
        return 0
    }

    func cmdInputBox(_ password: Bool) -> Int {
        var err = 0
        var s1 = getStrVal(&err)
        let s2 = getStrVal(&err)
        if err != 0 { return err }
        var s3: [UInt8] = []
        if !password && checkParameterGiven() {
            let p = linePtr
            s3 = getStrVal(&err)
            if err == E.typeMismatch { s3 = []; linePtr = p; err = 0 }
        }
        var sp = 0
        if checkParameterGiven() { sp = getIntVal(&err) }
        endOfLine(&err)
        if err != 0 { return err }
        if sp != 0 { s1 = restoreNewLine(s1) }
        setInputStr([])
        if let r = host?.ttlInputBox(s1.u8, title: s2.u8, defaultValue: s3.u8, secret: password) {
            setInputStr(ttlTrunc(r.ttl))
        } else {
            status = .end
            setInputStr([])
        }
        return 0
    }

    func cmdFilenameBox() -> Int {
        var err = 0
        let title = getStrVal(&err)
        if err != 0 { return err }
        var save = 0
        var initDir: [UInt8] = []
        if checkParameterGiven() {
            save = getIntVal(&err)
            if err != 0 { return err }
            if checkParameterGiven() {
                initDir = getStrVal(&err)
                if err != 0 { return err }
            }
        }
        endOfLine(&err)
        if err != 0 { return err }
        setInputStr([])
        let r = host?.ttlFileNameBox(title.u8, save: save != 0, initialDir: initDir.isEmpty ? nil : absPath(initDir))
        setInputStr((r ?? "").ttl)
        setResult(r == nil ? 0 : 1)
        return 0
    }

    func cmdDirnameBox() -> Int {
        var err = 0
        let title = getStrVal(&err)
        if err != 0 { return err }
        var initDir: [UInt8] = []
        if checkParameterGiven() {
            initDir = getStrVal(&err)
            if err != 0 { return err }
        }
        endOfLine(&err)
        if err != 0 { return err }
        setInputStr([])
        if let r = host?.ttlDirNameBox(title.u8, initialDir: initDir.isEmpty ? nil : absPath(initDir)) {
            setInputStr(r.ttl)
            setResult(1)
        } else {
            setResult(0)
        }
        return 0
    }

    // MARK: - クリップボード

    func cmdClipb2Var() -> Int {
        var err = 0
        let id = getStrVar(&err)
        if err != 0 { return err }
        var num = 0
        if checkParameterGiven() { num = getIntVal(&err) }
        endOfLine(&err)
        if err != 0 { return err }
        if num == 0 {
            if let s = host?.ttlGetClipboard() { clipboardCache = Array(s.utf8) } else { clipboardCache = nil; setResult(0); return 0 }
        }
        let chunk = MaxStrLen - 1
        if let cb = clipboardCache, num >= 0, num * chunk < cb.count {
            let start = num * chunk
            let piece = Array(cb[start..<min(cb.count, start + chunk)])
            setResult(start + chunk < cb.count ? 2 : 1)
            setStrVal(id, piece)
        } else {
            setResult(0)
        }
        return 0
    }

    func cmdVar2Clipb() -> Int {
        var err = 0
        let s = getStrVal(&err)
        if err != 0 { return err }
        setResult((host?.ttlSetClipboard(s.u8) ?? false) ? 1 : 0)
        return 0
    }

    // MARK: - そのほか

    func cmdBeep() -> Int {
        var err = 0
        if checkParameterGiven() {
            let v = getIntVal(&err)
            if err != 0 { return err }
            if v < 0 || v > 5 { return E.syntax }
        }
        host?.ttlBeep()
        return 0
    }
}
