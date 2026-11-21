/*
 * Tera Term Mac: C driver for Tera Term's file transfer protocols
 * (XMODEM, YMODEM, ZMODEM, Kermit, B-Plus, Quick-VAN).
 *
 * This is the only header visible to Swift.  It mirrors the parts of
 * teraterm/filesys_proto.cpp that create a protocol, pump Parse() and
 * report the result.  Not thread safe: all calls for one transfer (and the
 * callbacks) happen on the caller's thread / serial queue.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* protocol ids (filesys_proto.cpp ProtoId_t) */
enum {
	TERAFT_PROTO_KMT = 1,
	TERAFT_PROTO_XM  = 2,
	TERAFT_PROTO_ZM  = 3,
	TERAFT_PROTO_BP  = 4,
	TERAFT_PROTO_QV  = 5,
	TERAFT_PROTO_YM  = 6,
	TERAFT_PROTO_RAW = 7,	/* recvfile (ttpfile/raw.c), opt1 = auto stop seconds */
};

/* progress items (TInfoOp) */
enum {
	TERAFT_INFO_INIT_PROGRESS = 0,	/* a = 0 */
	TERAFT_INFO_TIME          = 1,	/* a = elapsed ms since start, b = bytes */
	TERAFT_INFO_PACKET_NUM    = 2,	/* a = packet number */
	TERAFT_INFO_BYTE_COUNT    = 3,	/* a = byte count */
	TERAFT_INFO_PERCENT       = 4,	/* a = done, b = total */
	TERAFT_INFO_PROTO_TEXT    = 5,	/* text = protocol description */
	TERAFT_INFO_FILE_NAME     = 6,	/* text = file name (full path) or NULL */
	TERAFT_INFO_MESSAGE       = 7,	/* text = error message (MessageBox) */
};

/* The subset of TTTSet / TComVar the protocols read */
typedef struct {
	int LogFlag;		/* LOG_KMT=2 LOG_X=4 LOG_Z=8 LOG_BP=16 LOG_QV=32 LOG_Y=64 */
	int FTFlag;		/* FT_ZESCCTL=1 FT_ZAUTO=2 FT_BPESCCTL=4 FT_BPAUTO=8 FT_RENAME=16 */
	int XmodemOpt, XmodemBin;
	int ZmodemDataLen, ZmodemWinSize;
	int QVWinSize;
	int DataBit;		/* IdDataBit7=1 IdDataBit8=2 */
	int Baud;
	int KermitOpt;		/* KmtOptLongPacket=1 KmtOptFileAttr=2 KmtOptSlideWin=4 */
	int XmodemTimeOutInit, XmodemTimeOutInitCRC, XmodemTimeOutShort, XmodemTimeOutLong, XmodemTimeOutVLong;
	int YmodemTimeOutInit, YmodemTimeOutInitCRC, YmodemTimeOutShort, YmodemTimeOutLong, YmodemTimeOutVLong;
	int ZmodemTimeOutNormal, ZmodemTimeOutTCPIP, ZmodemTimeOutInit, ZmodemTimeOutFin;
	int PortType;		/* IdTCPIP=1 IdSerial=2 */
	const char *XModemRcvCommand;	/* UTF-8, may be NULL */
	const char *YModemRcvCommand;
	const char *ZModemRcvCommand;
	const char *LogDir;		/* folder for XMODEM.LOG etc. (UTF-8), may be NULL */
	int NotReady;		/* 1 = start with cv.Ready == FALSE (not connected) */
} TeraFTSettings;

typedef struct {
	void *ctx;
	/* bytes to put on the line (CommBinaryOut) */
	void (*send)(void *ctx, const uint8_t *buf, size_t len);
	/* (re)arm the one-shot protocol timer; ms == 0 cancels it */
	void (*setTimer)(void *ctx, int ms);
	/* progress / dialog information */
	void (*info)(void *ctx, int item, int64_t a, int64_t b, const char *text);
} TeraFTCallbacks;

typedef struct TeraFT TeraFT;

/*
 * Create a protocol instance, like OpenProtoDlg() in filesys_proto.cpp.
 *  proto:  TERAFT_PROTO_*
 *  mode:   protocol mode (IdXReceive/IdXSend, IdKmtSend, ...)
 *  opt1, opt2: OpenProtoDlg Opt1/Opt2 (XMODEM: XmodemOpt / XmodemBin, ZMODEM: binary flag)
 *  files:  full paths (UTF-8), nfiles may be 0
 *  receivePath: folder with trailing '/', UTF-8
 *  overwrite: fv->OverWrite
 */
TeraFT *TeraFTCreate(int proto, int mode, int opt1, int opt2,
					 const TeraFTSettings *settings,
					 const char *const *files, int nfiles,
					 const char *receivePath, int overwrite, int noMsg,
					 TeraFTCallbacks callbacks);
/* Proto->Init(); 0 = failed */
int TeraFTInit(TeraFT *ft);
/* queue received bytes (they are moved to the 64 KB InBuff before each Parse) */
void TeraFTFeed(TeraFT *ft, const uint8_t *buf, size_t len);
/* CommReceive() + Proto->Parse(); returns 0 when the protocol has finished */
int TeraFTParse(TeraFT *ft);
void TeraFTTimeOut(TeraFT *ft);
void TeraFTCancel(TeraFT *ft);
/* fv->Success */
int TeraFTSuccess(const TeraFT *ft);
/* ProtoEnd() was called by the protocol itself */
int TeraFTEnded(const TeraFT *ft);
/* counter that changes whenever bytes are read, sent or the buffers change */
uint64_t TeraFTActivity(const TeraFT *ft);
/* cv.Ready: 0 after the session is gone. Parse() is then no longer called and
   the line I/O does nothing (like OnIdle / commlib); timers and Cancel still work. */
void TeraFTSetReady(TeraFT *ft, int ready);
int TeraFTIsReady(const TeraFT *ft);
/* move up to cap bytes that the protocol has not consumed (InBuff, then the
   pending queue) into buf; returns the number of bytes */
size_t TeraFTTakeBuffered(TeraFT *ft, uint8_t *buf, size_t cap);
/* bytes received but not yet consumed by the protocol */
size_t TeraFTBufferedBytes(const TeraFT *ft);
void TeraFTDestroy(TeraFT *ft);

#ifdef __cplusplus
}
#endif
