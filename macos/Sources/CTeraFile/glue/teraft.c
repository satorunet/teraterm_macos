/*
 * Tera Term Mac: file transfer protocol driver.
 *
 * Equivalent of the protocol part of teraterm/filesys_proto.cpp
 * (Tera Term Project, BSD 3-Clause): it builds the TFileVarProto, the TComm
 * (receive buffer like TComVar.InBuff, CommRead1Byte/CommInsert1Byte/
 * CommBinaryOut) and the TFileIO, creates the protocol the same way
 * OpenProtoDlg() does, and lets the caller pump Parse()/TimeOutProc().
 */
#include <windows.h>
#include <tttypes.h>
#include <assert.h>

#include "filesys_proto.h"
#include "filesys.h"
#include "codeconv.h"
#include "ttlib.h"

#include "kermit.h"
#include "xmodem.h"
#include "ymodem.h"
#include "zmodem.h"
#include "bplus.h"
#include "quickvan.h"
#include "raw.h"

#include "CTeraFile.h"
#include "teraft_internal.h"


struct TeraFT {
	TFileVarProto fv;
	TComm comm;
	TTTSet ts;
	TComVar cv;
	TeraFTCallbacks cb;

	/* the receive buffer is cv.InBuff / cv.InPtr / cv.InBuffCount (raw.c reads it directly) */

	/* bytes received from the line, not yet moved to InBuff */
	BYTE *pending;
	size_t pendingHead, pendingLen, pendingCap;

	uint64_t activity;
	BOOL ended;
	BOOL inited;
};

static _Thread_local TeraFT *CurrentFT = NULL;

/* ------------------------------------------------------------------ */
/* Win32 functions that need the current transfer                      */

/* filesys.h: called by a protocol when the session is gone (cv->Ready == FALSE) */
void ProtoEnd(void)
{
	if (CurrentFT != NULL) {
		CurrentFT->ended = TRUE;
		CurrentFT->cb.setTimer(CurrentFT->cb.ctx, 0);
	}
}

/* only used by zmodem.c: KillTimer(fv->HMainWin, IdProtoTimer); SetTimer(..., 500) */
UINT_PTR SetTimer(HWND hWnd, UINT_PTR id, UINT elapse_ms, void *func)
{
	(void)func;
	TeraFT *ft = (TeraFT *)hWnd;
	if (ft == NULL || id != IdProtoTimer) return 0;
	ft->cb.setTimer(ft->cb.ctx, elapse_ms == 0 ? 1 : (int)elapse_ms);
	return id;
}

BOOL KillTimer(HWND hWnd, UINT_PTR id)
{
	TeraFT *ft = (TeraFT *)hWnd;
	if (ft == NULL || id != IdProtoTimer) return FALSE;
	ft->cb.setTimer(ft->cb.ctx, 0);
	return TRUE;
}

void TeraFTReportMessage(const char *caption, const char *text)
{
	if (CurrentFT != NULL && CurrentFT->cb.info != NULL) {
		(void)caption;
		CurrentFT->cb.info(CurrentFT->cb.ctx, TERAFT_INFO_MESSAGE, 0, 0, text);
	}
}

/* ------------------------------------------------------------------ */
/* TComm                                                               */

static void FTCommReceive(TeraFT *ft)
{
	/* CommReceive() (commlib.c) */
	if (ft->cv.InBuffCount >= InBuffSize) return;
	if (ft->cv.InBuffCount == 0) {
		ft->cv.InPtr = 0;
	}
	else if (ft->cv.InPtr > 0 && ft->cv.InPtr + ft->cv.InBuffCount > InBuffSize / 4 * 3) {
		memmove(ft->cv.InBuff, &ft->cv.InBuff[ft->cv.InPtr], ft->cv.InBuffCount);
		ft->cv.InPtr = 0;
	}
	if (ft->cv.InPtr + ft->cv.InBuffCount < InBuffSize && ft->pendingLen > 0) {
		size_t space = InBuffSize - ft->cv.InPtr - ft->cv.InBuffCount;
		size_t n = ft->pendingLen < space ? ft->pendingLen : space;
		memcpy(&ft->cv.InBuff[ft->cv.InPtr + ft->cv.InBuffCount], ft->pending + ft->pendingHead, n);
		ft->cv.InBuffCount += (int)n;
		ft->pendingHead += n;
		ft->pendingLen -= n;
		if (ft->pendingLen == 0) ft->pendingHead = 0;
		ft->activity++;
	}
}

static int FTBinaryOut(struct Comm_ *comm, const CHAR *buf, size_t len)
{
	TeraFT *ft = (TeraFT *)comm->private_data;
	if (!ft->cv.Ready) return (int)len;	/* CommBinaryOut(): dropped while the session is gone */
	if (len > 0) {
		ft->cb.send(ft->cb.ctx, (const uint8_t *)buf, len);
		ft->activity++;
	}
	return (int)len;
}

static int FTRead1Byte(struct Comm_ *comm, BYTE *b)
{
	/* CommReadRawByte() */
	TeraFT *ft = (TeraFT *)comm->private_data;
	if (!ft->cv.Ready) return 0;
	if (ft->cv.InBuffCount > 0) {
		*b = ft->cv.InBuff[ft->cv.InPtr];
		ft->cv.InPtr++;
		ft->cv.InBuffCount--;
		if (ft->cv.InBuffCount == 0) ft->cv.InPtr = 0;
		ft->activity++;
		return 1;
	}
	ft->cv.InPtr = 0;
	return 0;
}

static void FTInsert1Byte(struct Comm_ *comm, BYTE b)
{
	/* CommInsert1Byte() */
	TeraFT *ft = (TeraFT *)comm->private_data;
	if (!ft->cv.Ready) return;
	if (ft->cv.InPtr == 0) {
		memmove(&ft->cv.InBuff[1], &ft->cv.InBuff[0], ft->cv.InBuffCount);
	}
	else {
		ft->cv.InPtr--;
	}
	ft->cv.InBuff[ft->cv.InPtr] = b;
	ft->cv.InBuffCount++;
	ft->activity++;
}

static void FTFlashReceiveBuf(struct Comm_ *comm)
{
	TeraFT *ft = (TeraFT *)comm->private_data;
	if (ft->cv.InBuffCount != 0) ft->activity++;
	ft->cv.InBuffCount = 0;
	ft->cv.InPtr = 0;
}

static const CommOp CommOpList = {
	FTBinaryOut,
	FTRead1Byte,
	FTInsert1Byte,
	FTFlashReceiveBuf,
};

/* ------------------------------------------------------------------ */
/* TFileVarProto services                                              */

static char *GetNextFname(PFileVarProto fv)
{
	wchar_t *f = fv->FileNames == NULL ? NULL : fv->FileNames[fv->FNCount];
	if (f == NULL) {
		return NULL;
	}
	fv->FNCount++;
	return ToU8W(f);
}

static char *GetRecievePath(struct FileVarProto *fv)
{
	return ToU8W(fv->RecievePath);
}

static void FTSetTimeOut(PFileVarProto fv, int T)
{
	TeraFT *ft = (TeraFT *)fv->HMainWin;
	ft->cb.setTimer(ft->cb.ctx, 0);
	if (T == 0) return;
	ft->cb.setTimer(ft->cb.ctx, T * 1000);
}

static void SetDialogCation(struct FileVarProto *fv, const char *key, const wchar_t *default_caption)
{
	(void)key;
	free(fv->DlgCaption);
	fv->DlgCaption = _wcsdup(default_caption);
}

static void Info(struct FileVarProto *fv, int item, int64_t a, int64_t b, const char *text)
{
	TeraFT *ft = (TeraFT *)fv->HMainWin;
	if (ft->cb.info != NULL) {
		ft->cb.info(ft->cb.ctx, item, a, b, text);
	}
}

static void _InitDlgProgress(struct FileVarProto *fv, int *CurProgStat)
{
	*CurProgStat = 0;
	Info(fv, TERAFT_INFO_INIT_PROGRESS, 0, 0, NULL);
}

static void _SetDlgTime(struct FileVarProto *fv, DWORD stime, int bytes)
{
	Info(fv, TERAFT_INFO_TIME, (int64_t)(DWORD)(GetTickCount() - stime), bytes, NULL);
}

static void _SetDlgPacketNum(struct FileVarProto *fv, LONG Num)
{
	Info(fv, TERAFT_INFO_PACKET_NUM, Num, 0, NULL);
}

static void _SetDlgByteCount(struct FileVarProto *fv, LONG Num)
{
	Info(fv, TERAFT_INFO_BYTE_COUNT, Num, 0, NULL);
}

static void _SetDlgPercent(struct FileVarProto *fv, LONG a, LONG b, int *p)
{
	/* dlglib.c SetDlgPercent() */
	double Num = (b == 0) ? 100.0 : 100.0 * (double)a / (double)b;
	if (p != NULL && *p >= 0 && (double)*p < Num) {
		*p = (int)Num;
	}
	Info(fv, TERAFT_INFO_PERCENT, a, b, NULL);
}

static void _SetDlgProtoText(struct FileVarProto *fv, const char *text)
{
	Info(fv, TERAFT_INFO_PROTO_TEXT, 0, 0, text);
}

static void _SetDlgProtoFileName(struct FileVarProto *fv, const char *text)
{
	Info(fv, TERAFT_INFO_FILE_NAME, 0, 0, text);
}

static const TInfoOp InfoOp = {
	_InitDlgProgress,
	_SetDlgTime,
	_SetDlgPacketNum,
	_SetDlgByteCount,
	_SetDlgPercent,
	_SetDlgProtoText,
	_SetDlgProtoFileName,
};

/* ------------------------------------------------------------------ */

static wchar_t *DupW(const char *u8)
{
	if (u8 == NULL) return NULL;
	wchar_t *w = ToWcharU8(u8);
	return w != NULL ? w : ToWcharA(u8);
}

static void CopyCmd(char *dst, const char *src)
{
	strncpy_s(dst, MAX_PATH, src != NULL ? src : "", _TRUNCATE);
}

TeraFT *TeraFTCreate(int proto, int mode, int opt1, int opt2,
					 const TeraFTSettings *s,
					 const char *const *files, int nfiles,
					 const char *receivePath, int overwrite, int noMsg,
					 TeraFTCallbacks callbacks)
{
	TeraFT *ft = calloc(1, sizeof(TeraFT));
	if (ft == NULL) return NULL;
	ft->cb = callbacks;

	/* ts */
	TTTSet *ts = &ft->ts;
	ts->LogFlag = (WORD)s->LogFlag;
	ts->FTFlag = (WORD)s->FTFlag;
	ts->XmodemOpt = (WORD)s->XmodemOpt;
	ts->XmodemBin = (WORD)s->XmodemBin;
	ts->ZmodemDataLen = s->ZmodemDataLen;
	ts->ZmodemWinSize = s->ZmodemWinSize;
	ts->QVWinSize = s->QVWinSize;
	ts->DataBit = (WORD)s->DataBit;
	ts->Baud = (DWORD)s->Baud;
	ts->KermitOpt = (WORD)s->KermitOpt;
	ts->XmodemTimeOutInit = s->XmodemTimeOutInit;
	ts->XmodemTimeOutInitCRC = s->XmodemTimeOutInitCRC;
	ts->XmodemTimeOutShort = s->XmodemTimeOutShort;
	ts->XmodemTimeOutLong = s->XmodemTimeOutLong;
	ts->XmodemTimeOutVLong = s->XmodemTimeOutVLong;
	ts->YmodemTimeOutInit = s->YmodemTimeOutInit;
	ts->YmodemTimeOutInitCRC = s->YmodemTimeOutInitCRC;
	ts->YmodemTimeOutShort = s->YmodemTimeOutShort;
	ts->YmodemTimeOutLong = s->YmodemTimeOutLong;
	ts->YmodemTimeOutVLong = s->YmodemTimeOutVLong;
	ts->ZmodemTimeOutNormal = s->ZmodemTimeOutNormal;
	ts->ZmodemTimeOutTCPIP = s->ZmodemTimeOutTCPIP;
	ts->ZmodemTimeOutInit = s->ZmodemTimeOutInit;
	ts->ZmodemTimeOutFin = s->ZmodemTimeOutFin;
	CopyCmd(ts->XModemRcvCommand, s->XModemRcvCommand);
	CopyCmd(ts->YModemRcvCommand, s->YModemRcvCommand);
	CopyCmd(ts->ZModemRcvCommand, s->ZModemRcvCommand);
	ts->UILanguageFileW = DupW("");
	ts->LogDirW = DupW(s->LogDir != NULL ? s->LogDir : ".");

	/* cv */
	ft->cv.PortType = (WORD)s->PortType;
	ft->cv.Ready = s->NotReady ? FALSE : TRUE;
	ft->cv.OutBuffCount = 0;	/* everything is handed to send() immediately */

	/* comm */
	ft->comm.op = &CommOpList;
	ft->comm.private_data = ft;

	/* fv (NewFileVar_()) */
	PFileVarProto fv = &ft->fv;
	fv->HMainWin = (HWND)ft;
	fv->HWin = (HWND)ft;
	fv->RecievePath = DupW(receivePath != NULL ? receivePath : "");
	fv->OverWrite = overwrite ? TRUE : FALSE;
	fv->Success = FALSE;
	fv->NoMsg = noMsg ? TRUE : FALSE;
	fv->file_fv = TeraFTFilesysCreatePosix();
	fv->GetNextFname = GetNextFname;
	fv->GetRecievePath = GetRecievePath;
	fv->FTSetTimeOut = FTSetTimeOut;
	fv->SetDialogCation = SetDialogCation;
	fv->InfoOp = &InfoOp;
	fv->Comm = &ft->comm;

	if (nfiles > 0) {
		fv->FileNames = calloc((size_t)nfiles + 1, sizeof(wchar_t *));
		for (int i = 0; i < nfiles; i++) {
			fv->FileNames[i] = DupW(files[i]);
		}
	}

	/* OpenProtoDlg() */
	TProto *p = NULL;
	CurrentFT = ft;
	switch (proto) {
	case TERAFT_PROTO_KMT:
		p = KmtCreate(fv);
		if (p) p->Op->SetOpt(p, KMT_MODE, mode);
		break;
	case TERAFT_PROTO_XM:
		p = XCreate(fv);
		if (p) {
			p->Op->SetOpt(p, XMODEM_MODE, mode);
			p->Op->SetOpt(p, XMODEM_OPT, opt1);
			p->Op->SetOpt(p, XMODEM_TEXT_FLAG, 1 - (opt2 & 1));
		}
		break;
	case TERAFT_PROTO_YM:
		p = YCreate(fv);
		if (p) {
			p->Op->SetOpt(p, YMODEM_MODE, mode);
			p->Op->SetOpt(p, YMODEM_OPT, opt1);
		}
		break;
	case TERAFT_PROTO_ZM:
		p = ZCreate(fv);
		if (p) {
			p->Op->SetOpt(p, ZMODEM_MODE, mode);
			p->Op->SetOpt(p, ZMODEM_BINFLAG, (opt1 & 1) != 0);
		}
		break;
	case TERAFT_PROTO_BP:
		p = BPCreate(fv);
		if (p) p->Op->SetOpt(p, BPLUS_MODE, mode);
		break;
	case TERAFT_PROTO_QV:
		p = QVCreate(fv);
		if (p) p->Op->SetOpt(p, QUICKVAN_MODE, mode);
		break;
	case TERAFT_PROTO_RAW:
		p = RawCreate(fv);
		if (p) p->Op->SetOpt(p, RAW_AUTOSTOP_SEC, opt1);
		break;
	default:
		break;
	}
	CurrentFT = NULL;
	if (p == NULL) {
		TeraFTDestroy(ft);
		return NULL;
	}
	fv->Proto = p;
	return ft;
}

int TeraFTInit(TeraFT *ft)
{
	TeraFT *saved = CurrentFT;
	CurrentFT = ft;
	BOOL r = ft->fv.Proto->Op->Init(ft->fv.Proto, &ft->cv, &ft->ts);
	CurrentFT = saved;
	ft->inited = r;
	return r ? 1 : 0;
}

void TeraFTFeed(TeraFT *ft, const uint8_t *buf, size_t len)
{
	if (len == 0) return;
	if (ft->pendingHead > 0 && ft->pendingHead + ft->pendingLen + len > ft->pendingCap) {
		memmove(ft->pending, ft->pending + ft->pendingHead, ft->pendingLen);
		ft->pendingHead = 0;
	}
	if (ft->pendingHead + ft->pendingLen + len > ft->pendingCap) {
		size_t cap = ft->pendingCap ? ft->pendingCap : 65536;
		while (cap < ft->pendingLen + len) cap *= 2;
		ft->pending = realloc(ft->pending, cap);
		ft->pendingCap = cap;
	}
	memcpy(ft->pending + ft->pendingHead + ft->pendingLen, buf, len);
	ft->pendingLen += len;
	ft->activity++;
}

int TeraFTParse(TeraFT *ft)
{
	if (ft->ended) return 0;
	/* teraterm.cpp OnIdle(): ProtoDlgParse() only runs while cv.Ready */
	if (!ft->cv.Ready) return 1;
	TeraFT *saved = CurrentFT;
	CurrentFT = ft;
	FTCommReceive(ft);
	BOOL r = ft->fv.Proto->Op->Parse(ft->fv.Proto);
	CurrentFT = saved;
	if (ft->ended) return 0;
	return r ? 1 : 0;
}

void TeraFTTimeOut(TeraFT *ft)
{
	if (ft->ended) return;
	TeraFT *saved = CurrentFT;
	CurrentFT = ft;
	ft->fv.Proto->Op->TimeOutProc(ft->fv.Proto);
	CurrentFT = saved;
	ft->activity++;
}

void TeraFTCancel(TeraFT *ft)
{
	if (ft->ended) return;
	TeraFT *saved = CurrentFT;
	CurrentFT = ft;
	ft->fv.Proto->Op->Cancel(ft->fv.Proto);
	CurrentFT = saved;
	ft->activity++;
}

int TeraFTSuccess(const TeraFT *ft)
{
	return ft->fv.Success ? 1 : 0;
}

int TeraFTEnded(const TeraFT *ft)
{
	return ft->ended ? 1 : 0;
}

uint64_t TeraFTActivity(const TeraFT *ft)
{
	return ft->activity;
}

void TeraFTSetReady(TeraFT *ft, int ready)
{
	ft->cv.Ready = ready ? TRUE : FALSE;
	ft->activity++;
}

int TeraFTIsReady(const TeraFT *ft)
{
	return ft->cv.Ready ? 1 : 0;
}

size_t TeraFTTakeBuffered(TeraFT *ft, uint8_t *buf, size_t cap)
{
	size_t n = 0;
	if (ft->cv.InBuffCount > 0) {
		size_t c = (size_t)ft->cv.InBuffCount;
		if (c > cap) c = cap;
		memcpy(buf, &ft->cv.InBuff[ft->cv.InPtr], c);
		n += c;
		ft->cv.InPtr += (int)c;
		ft->cv.InBuffCount -= (int)c;
		if (ft->cv.InBuffCount == 0) ft->cv.InPtr = 0;
	}
	if (n < cap && ft->pendingLen > 0) {
		size_t c = ft->pendingLen;
		if (c > cap - n) c = cap - n;
		memcpy(buf + n, ft->pending + ft->pendingHead, c);
		n += c;
		ft->pendingHead += c;
		ft->pendingLen -= c;
		if (ft->pendingLen == 0) ft->pendingHead = 0;
	}
	return n;
}

size_t TeraFTBufferedBytes(const TeraFT *ft)
{
	return ft->pendingLen + (size_t)ft->cv.InBuffCount;
}

void TeraFTDestroy(TeraFT *ft)
{
	if (ft == NULL) return;
	TeraFT *saved = CurrentFT;
	CurrentFT = ft;
	PFileVarProto fv = &ft->fv;
	if (fv->Proto != NULL) {
		fv->Proto->Op->Destroy(fv->Proto);
		fv->Proto = NULL;
	}
	CurrentFT = saved;
	if (fv->FileNames != NULL) {
		for (int i = 0; fv->FileNames[i] != NULL; i++) free(fv->FileNames[i]);
		free(fv->FileNames);
	}
	if (fv->file_fv != NULL) fv->file_fv->FileSysDestroy(fv->file_fv);
	free(fv->DlgCaption);
	free(fv->RecievePath);
	free(ft->ts.UILanguageFileW);
	free(ft->ts.LogDirW);
	free(ft->pending);
	free(ft);
}
