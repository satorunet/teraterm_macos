/*
 * Tera Term Mac: minimal replacement for common/tttypes.h.
 * TTTSet / TComVar contain only the members the file-transfer protocols read.
 * Constant values are identical to the original tttypes.h.
 */
#pragma once

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IdProtoTimer 3

/* port types */
#define IdTCPIP     1
#define IdSerial    2
#define IdFile      3
#define IdNamedPipe 4

/* log flags (used in ts.LogFlag) */
#define LOG_TEL 1
#define LOG_KMT 2
#define LOG_X   4
#define LOG_Z   8
#define LOG_BP  16
#define LOG_QV  32
#define LOG_Y   64

/* file transfer flags (used in ts.FTFlag) */
#define FT_ZESCCTL  1
#define FT_ZAUTO    2
#define FT_BPESCCTL 4
#define FT_BPAUTO   8
#define FT_RENAME   16

/* data bits */
#define IdDataBit7 1
#define IdDataBit8 2

/* ASCII control characters */
#define SOH  0x01
#define STX  0x02
#define ETX  0x03
#define EOT  0x04
#define ENQ  0x05
#define ACK  0x06
#define BEL  0x07
#define BS   0x08
#define HT   0x09
#define LF   0x0A
#define VT   0x0B
#define FF   0x0C
#define CR   0x0D
#define SO   0x0E
#define SI   0x0F
#define DLE  0x10
#define DC1  0x11
#define XON  0x11
#define DC2  0x12
#define DC3  0x13
#define XOFF 0x13
#define DC4  0x14
#define NAK  0x15
#define SYN  0x16
#define ETB  0x17
#define CAN  0x18
#define EM   0x19
#define SUB  0x1A
#define ESC  0x1B
#define FS   0x1C
#define GS   0x1D
#define RS   0x1E
#define US   0x1F
#define SP   0x20
#define DEL  0x7F

struct tttset {
	WORD LogFlag;
	WORD FTFlag;
	WORD XmodemOpt, XmodemBin;
	int ZmodemDataLen, ZmodemWinSize;
	int QVWinSize;
	WORD DataBit;
	char XModemRcvCommand[MAX_PATH];
	char ZModemRcvCommand[MAX_PATH];
	char YModemRcvCommand[MAX_PATH];
	DWORD Baud;
	WORD KermitOpt;
	int XmodemTimeOutInit;
	int XmodemTimeOutInitCRC;
	int XmodemTimeOutShort;
	int XmodemTimeOutLong;
	int XmodemTimeOutVLong;
	int YmodemTimeOutInit;
	int YmodemTimeOutInitCRC;
	int YmodemTimeOutShort;
	int YmodemTimeOutLong;
	int YmodemTimeOutVLong;
	int ZmodemTimeOutNormal;
	int ZmodemTimeOutTCPIP;
	int ZmodemTimeOutInit;
	int ZmodemTimeOutFin;
	wchar_t *UILanguageFileW;
	wchar_t *LogDirW;
};
typedef struct tttset TTTSet, *PTTSet;

#ifndef InBuffSize
#define InBuffSize (1024 * 64)
#endif

typedef struct tcomvar {
	/* receive buffer (TComVar.InBuff), read directly by raw.c */
	BYTE InBuff[InBuffSize + 16];
	int InPtr;
	int InBuffCount;
	int OutBuffCount;
	WORD PortType;
	BOOL Ready;
} TComVar;
typedef TComVar *PComVar;

/* common/ttlib.h */
typedef struct {
	const char *section;
	const char *title_key;
	const wchar_t *title_default;
	const char *message_key;
	const wchar_t *message_default;
	UINT uType;
} TTMessageBoxInfoW;
int TTMessageBoxW(HWND hWnd, const TTMessageBoxInfoW *info, const wchar_t *UILanguageFile, ...);

#ifdef __cplusplus
}
#endif
