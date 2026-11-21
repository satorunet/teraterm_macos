// Generated from teraterm/ttpmacro/ttmparse.h and ttmparse.cpp (Tera Term, BSD 3-Clause)
enum Rsv: Int {
    case beep = 1
    case bPlusRecv = 2
    case bPlusSend = 3
    case call = 4
    case changeDir = 5
    case clearScreen = 6
    case closeSBox = 7
    case closeTT = 8
    case code2Str = 9
    case connect = 10
    case delPassword = 11
    case disconnect = 12
    case `else` = 13
    case elseIf = 14
    case enableKeyb = 15
    case end = 16
    case endIf = 17
    case endWhile = 18
    case exec = 19
    case execCmnd = 20
    case exit = 21
    case fileClose = 22
    case fileConcat = 23
    case fileCopy = 24
    case fileCreate = 25
    case fileDelete = 26
    case fileMarkPtr = 27
    case fileOpen = 28
    case fileReadln = 29
    case fileRename = 30
    case fileSearch = 31
    case fileSeek = 32
    case fileSeekBack = 33
    case fileStrSeek = 34
    case fileStrSeek2 = 35
    case fileWrite = 36
    case fileWriteLn = 37
    case findClose = 38
    case findFirst = 39
    case findNext = 40
    case flushRecv = 41
    case `for` = 42
    case getDate = 43
    case getDir = 44
    case getEnv = 45
    case getPassword = 46
    case getTime = 47
    case getTitle = 48
    case goto = 49
    case `if` = 50
    case include = 51
    case inputBox = 52
    case int2Str = 53
    case kmtFinish = 54
    case kmtGet = 55
    case kmtRecv = 56
    case kmtSend = 57
    case loadKeyMap = 58
    case logClose = 59
    case logOpen = 60
    case logPause = 61
    case logStart = 62
    case logWrite = 63
    case makePath = 64
    case messageBox = 65
    case next = 66
    case passwordBox = 67
    case pause = 68
    case quickVANRecv = 69
    case quickVANSend = 70
    case recvLn = 71
    case restoreSetup = 72
    case `return` = 73
    case send = 74
    case sendBreak = 75
    case sendFile = 76
    case sendKCode = 77
    case sendLn = 78
    case setDate = 79
    case setDir = 80
    case setDlgPos = 81
    case setEcho = 82
    case setExitCode = 83
    case setSync = 84
    case setTime = 85
    case setTitle = 86
    case show = 87
    case showTT = 88
    case statusBox = 89
    case str2Code = 90
    case str2Int = 91
    case strCompare = 92
    case strConcat = 93
    case strCopy = 94
    case strLen = 95
    case strScan = 96
    case testLink = 97
    case then = 98
    case unlink = 99
    case wait = 100
    case waitEvent = 101
    case waitLn = 102
    case waitRecv = 103
    case `while` = 104
    case xmodemRecv = 105
    case xmodemSend = 106
    case yesNoBox = 107
    case zmodemRecv = 108
    case zmodemSend = 109
    case waitRegex = 110
    case milliPause = 111
    case random = 112
    case clipb2Var = 113
    case var2Clipb = 114
    case ifDefined = 115
    case fileRead = 116
    case sprintf = 117
    case toLower = 118
    case toUpper = 119
    case `break` = 120
    case rotateR = 121
    case rotateL = 122
    case setEnv = 123
    case filenameBox = 124
    case callMenu = 125
    case `do` = 126
    case loop = 127
    case until = 128
    case endUntil = 129
    case cygConnect = 130
    case scpRecv = 131
    case scpSend = 132
    case getVer = 133
    case setBaud = 134
    case strMatch = 135
    case setRts = 136
    case setDtr = 137
    case crc32 = 138
    case crc32File = 139
    case getTTDir = 140
    case getHostname = 141
    case sprintf2 = 142
    case waitN = 143
    case sendBroadcast = 144
    case sendMulticast = 145
    case setMulticastName = 146
    case sendlnBroadcast = 147
    case wait4all = 148
    case dispStr = 149
    case intDim = 150
    case strDim = 151
    case logInfo = 152
    case fileLock = 153
    case fileUnLock = 154
    case `continue` = 155
    case regexOption = 156
    case sendlnMulticast = 157
    case recvFile = 158
    case delVar = 159
    case reDim = 160
    case setDebug = 175
    case ymodemRecv = 176
    case ymodemSend = 177
    case fileStat = 178
    case fileTruncate = 179
    case strInsert = 180
    case strRemove = 181
    case strReplace = 182
    case strTrim = 183
    case strSplit = 184
    case strJoin = 185
    case strSpecial = 186
    case basename = 187
    case dirname = 188
    case getFileAttr = 189
    case setFileAttr = 190
    case folderCreate = 191
    case folderDelete = 192
    case folderSearch = 193
    case expandEnv = 194
    case getSpecialFolder = 195
    case setPassword = 196
    case isPassword = 197
    case listBox = 198
    case getIPv4Addr = 199
    case getIPv6Addr = 200
    case logRotate = 201
    case crc16 = 202
    case crc16File = 203
    case checksum8 = 204
    case checksum8File = 205
    case checksum16 = 206
    case checksum16File = 207
    case checksum32 = 208
    case checksum32File = 209
    case bringupBox = 210
    case logAutoClose = 211
    case uptime = 212
    case getModemStatus = 213
    case dirnameBox = 214
    case setFlowCtrl = 215
    case sendText = 217
    case sendBinary = 218
    case setPassword2 = 219
    case getPassword2 = 220
    case delPassword2 = 221
    case isPassword2 = 222
    case getTTPos = 223
    case setSerialDelayChar = 224
    case setSerialDelayLine = 225
    case operator_ = 1000
    case bNot = 1001
    case bAnd = 1002
    case bOr = 1003
    case bXor = 1004
    case mul = 1005
    case plus = 1006
    case minus = 1007
    case div = 1008
    case mod = 1009
    case lT = 1010
    case eQ = 1011
    case gT = 1012
    case lE = 1013
    case nE = 1014
    case gE = 1015
    case lNot = 1016
    case lAnd = 1017
    case lOr = 1018
    case lXor = 1019
    case aRShift = 1020
    case aLShift = 1021
    case lRShift = 1022
}

let ttlReservedWords: [String: Rsv] = [
    "and": .bAnd,
    "beep": .beep,
    "bplusrecv": .bPlusRecv,
    "bplussend": .bPlusSend,
    "break": .break,
    "bringupbox": .bringupBox,
    "basename": .basename,
    "call": .call,
    "callmenu": .callMenu,
    "changedir": .changeDir,
    "checksum8": .checksum8,
    "checksum8file": .checksum8File,
    "checksum16": .checksum16,
    "checksum16file": .checksum16File,
    "checksum32": .checksum32,
    "checksum32file": .checksum32File,
    "clearscreen": .clearScreen,
    "clipb2var": .clipb2Var,
    "closesbox": .closeSBox,
    "closett": .closeTT,
    "code2str": .code2Str,
    "connect": .connect,
    "continue": .continue,
    "crc16": .crc16,
    "crc16file": .crc16File,
    "crc32": .crc32,
    "crc32file": .crc32File,
    "cygconnect": .cygConnect,
    "delpassword": .delPassword,
    "delpassword2": .delPassword2,
    "delvar": .delVar,
    "disconnect": .disconnect,
    "dispstr": .dispStr,
    "do": .do,
    "dirname": .dirname,
    "dirnamebox": .dirnameBox,
    "else": .else,
    "elseif": .elseIf,
    "enablekeyb": .enableKeyb,
    "end": .end,
    "endif": .endIf,
    "enduntil": .endUntil,
    "endwhile": .endWhile,
    "exec": .exec,
    "execcmnd": .execCmnd,
    "exit": .exit,
    "expandenv": .expandEnv,
    "fileclose": .fileClose,
    "fileconcat": .fileConcat,
    "filecopy": .fileCopy,
    "filecreate": .fileCreate,
    "filedelete": .fileDelete,
    "filelock": .fileLock,
    "filemarkptr": .fileMarkPtr,
    "filenamebox": .filenameBox,
    "fileopen": .fileOpen,
    "filereadln": .fileReadln,
    "fileread": .fileRead,
    "filerename": .fileRename,
    "filesearch": .fileSearch,
    "fileseek": .fileSeek,
    "fileseekback": .fileSeekBack,
    "filestat": .fileStat,
    "filestrseek": .fileStrSeek,
    "filestrseek2": .fileStrSeek2,
    "filetruncate": .fileTruncate,
    "fileunlock": .fileUnLock,
    "filewrite": .fileWrite,
    "filewriteln": .fileWriteLn,
    "findclose": .findClose,
    "findfirst": .findFirst,
    "findnext": .findNext,
    "flushrecv": .flushRecv,
    "foldercreate": .folderCreate,
    "folderdelete": .folderDelete,
    "foldersearch": .folderSearch,
    "for": .for,
    "getdate": .getDate,
    "getdir": .getDir,
    "getenv": .getEnv,
    "getfileattr": .getFileAttr,
    "gethostname": .getHostname,
    "getipv4addr": .getIPv4Addr,
    "getipv6addr": .getIPv6Addr,
    "getmodemstatus": .getModemStatus,
    "getpassword": .getPassword,
    "getpassword2": .getPassword2,
    "getspecialfolder": .getSpecialFolder,
    "gettime": .getTime,
    "gettitle": .getTitle,
    "getttdir": .getTTDir,
    "getttpos": .getTTPos,
    "getver": .getVer,
    "goto": .goto,
    "if": .if,
    "ifdefined": .ifDefined,
    "include": .include,
    "inputbox": .inputBox,
    "int2str": .int2Str,
    "intdim": .intDim,
    "ispassword": .isPassword,
    "ispassword2": .isPassword2,
    "kmtfinish": .kmtFinish,
    "kmtget": .kmtGet,
    "kmtrecv": .kmtRecv,
    "kmtsend": .kmtSend,
    "listbox": .listBox,
    "loadkeymap": .loadKeyMap,
    "logautoclosemode": .logAutoClose,
    "logclose": .logClose,
    "loginfo": .logInfo,
    "logopen": .logOpen,
    "logpause": .logPause,
    "logrotate": .logRotate,
    "logstart": .logStart,
    "logwrite": .logWrite,
    "loop": .loop,
    "makepath": .makePath,
    "messagebox": .messageBox,
    "mpause": .milliPause,
    "next": .next,
    "not": .bNot,
    "or": .bOr,
    "passwordbox": .passwordBox,
    "pause": .pause,
    "quickvanrecv": .quickVANRecv,
    "quickvansend": .quickVANSend,
    "random": .random,
    "recvln": .recvLn,
    "recvfile": .recvFile,
    "redim": .reDim,
    "regexoption": .regexOption,
    "restoresetup": .restoreSetup,
    "return": .return,
    "rotateleft": .rotateL,
    "rotateright": .rotateR,
    "scprecv": .scpRecv,
    "scpsend": .scpSend,
    "send": .send,
    "sendbreak": .sendBreak,
    "sendbroadcast": .sendBroadcast,
    "sendlnbroadcast": .sendlnBroadcast,
    "sendlnmulticast": .sendlnMulticast,
    "sendmulticast": .sendMulticast,
    "sendtext": .sendText,
    "sendbinary": .sendBinary,
    "setfileattr": .setFileAttr,
    "setmulticastname": .setMulticastName,
    "sendfile": .sendFile,
    "sendkcode": .sendKCode,
    "sendln": .sendLn,
    "setbaud": .setBaud,
    "setdate": .setDate,
    "setdebug": .setDebug,
    "setdir": .setDir,
    "setdlgpos": .setDlgPos,
    "setdtr": .setDtr,
    "setecho": .setEcho,
    "setenv": .setEnv,
    "setexitcode": .setExitCode,
    "setflowctrl": .setFlowCtrl,
    "setpassword": .setPassword,
    "setpassword2": .setPassword2,
    "setrts": .setRts,
    "setserialdelaychar": .setSerialDelayChar,
    "setserialdelayline": .setSerialDelayLine,
    "setspeed": .setBaud,
    "setsync": .setSync,
    "settime": .setTime,
    "settitle": .setTitle,
    "show": .show,
    "showtt": .showTT,
    "sprintf": .sprintf,
    "sprintf2": .sprintf2,
    "statusbox": .statusBox,
    "str2code": .str2Code,
    "str2int": .str2Int,
    "strcompare": .strCompare,
    "strconcat": .strConcat,
    "strcopy": .strCopy,
    "strdim": .strDim,
    "strinsert": .strInsert,
    "strjoin": .strJoin,
    "strlen": .strLen,
    "strmatch": .strMatch,
    "strremove": .strRemove,
    "strreplace": .strReplace,
    "strscan": .strScan,
    "strspecial": .strSpecial,
    "strsplit": .strSplit,
    "strtrim": .strTrim,
    "testlink": .testLink,
    "then": .then,
    "tolower": .toLower,
    "toupper": .toUpper,
    "unlink": .unlink,
    "until": .until,
    "uptime": .uptime,
    "var2clipb": .var2Clipb,
    "waitregex": .waitRegex,
    "wait": .wait,
    "wait4all": .wait4all,
    "waitevent": .waitEvent,
    "waitln": .waitLn,
    "waitn": .waitN,
    "waitrecv": .waitRecv,
    "while": .while,
    "xmodemrecv": .xmodemRecv,
    "xmodemsend": .xmodemSend,
    "xor": .bXor,
    "yesnobox": .yesNoBox,
    "ymodemrecv": .ymodemRecv,
    "ymodemsend": .ymodemSend,
    "zmodemrecv": .zmodemRecv,
    "zmodemsend": .zmodemSend,
]
