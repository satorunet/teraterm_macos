/*
 * Tera Term Mac: POSIX implementation of TFileIO (ttpfile/filesys_io.h).
 * Port of ttpfile/filesys_win32.cpp (Tera Term Project, BSD 3-Clause).
 *
 * File names are UTF-8.  Where the Windows version converts to/from the
 * "ANSI" code page, macOS uses UTF-8 (received names that are not valid
 * UTF-8 are converted from CP932, the code page of Japanese Windows).
 */
#include <windows.h>
#include <sys/utime.h>
#include <ctype.h>
#include <errno.h>
#include <iconv.h>
#include <unistd.h>

#include "filesys_io.h"
#include "codeconv.h"
#include "teraft_internal.h"

typedef struct {
	FILE *fp;
} TFileIOPosix;

static BOOL _OpenRead(TFileIO *fv, const char *filenameU8)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	data->fp = fopen(filenameU8, "rb");
	return data->fp != NULL;
}

static BOOL _OpenWrite(TFileIO *fv, const char *filenameU8)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	data->fp = fopen(filenameU8, "wb");	/* CREATE_ALWAYS */
	return data->fp != NULL;
}

static size_t _ReadFile(TFileIO *fv, void *buf, size_t bytes)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	if (data->fp == NULL) return 0;
	return fread(buf, 1, bytes, data->fp);
}

static size_t _WriteFile(TFileIO *fv, const void *buf, size_t bytes)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	if (data->fp == NULL) return 0;
	return fwrite(buf, 1, bytes, data->fp);
}

static void _Close(TFileIO *fv)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	if (data->fp != NULL) {
		fclose(data->fp);
		data->fp = NULL;
	}
}

static size_t _GetFSize(TFileIO *fv, const char *filenameU8)
{
	(void)fv;
	struct stat st;
	if (stat(filenameU8, &st) != 0) return 0;
	return (size_t)st.st_size;
}

static int _Seek(TFileIO *fv, size_t offset)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	if (data->fp == NULL) return -1;
	return fseeko(data->fp, (off_t)offset, SEEK_SET) == 0 ? 0 : -1;
}

static int _stat_(TFileIO *fv, const char *filenameU8, struct _stati64 *st)
{
	(void)fv;
	return stat(filenameU8, st);
}

static int _utime_(TFileIO *fv, const char *filenameU8, struct _utimbuf *const t)
{
	(void)fv;
	return utime(filenameU8, t);
}

/* ttlib GetFileNamePosU8() */
static BOOL GetFileNamePosU8(const char *PathName, int *DirLen, int *FNPos)
{
	BYTE b;
	const char *Ptr;
	const char *DirPtr;
	const char *FNPtr;
	const char *PtrOld;

	if (DirLen != NULL) *DirLen = 0;
	if (FNPos != NULL) *FNPos = 0;

	if (PathName == NULL)
		return FALSE;

	if ((strlen(PathName) >= 2) && (PathName[1] == ':'))
		Ptr = &PathName[2];
	else
		Ptr = PathName;
	if (Ptr[0] == '\\' || Ptr[0] == '/')
		Ptr++;

	DirPtr = Ptr;
	FNPtr = Ptr;
	while (Ptr[0] != 0) {
		b = Ptr[0];
		PtrOld = Ptr;
		Ptr++;
		switch (b) {
		case ':':
			return FALSE;
		case '/':	/* FALLTHROUGH */
		case '\\':
			DirPtr = PtrOld;
			FNPtr = Ptr;
			break;
		}
	}
	if (DirLen != NULL) *DirLen = (int)(DirPtr - PathName);
	if (FNPos != NULL) *FNPos = (int)(FNPtr - PathName);
	return TRUE;
}

// replace ' ' by '_' in FName
static void FTConvFName(PCHAR FName)
{
	int i = 0;
	while (FName[i] != 0) {
		if (FName[i] == ' ')
			FName[i] = '_';
		i++;
	}
}

static char *GetSendFilename(TFileIO *fv, const char *fullnameU8, BOOL utf8, BOOL space, BOOL upper)
{
	(void)fv;
	(void)utf8;	/* "ANSI" == UTF-8 on macOS */
	int FnPos;
	GetFileNamePosU8(fullnameU8, NULL, &FnPos);
	char *filename = strdup(fullnameU8 + FnPos);
	if (filename == NULL) return NULL;
	if (space) {
		FTConvFName(filename);
	}
	if (upper) {
		for (char *p = filename; *p; p++) {
			*p = (char)toupper((unsigned char)*p);	/* _strupr() */
		}
	}
	return filename;
}

static BOOL DoesFileExist(const char *pathU8)
{
	struct stat st;
	return stat(pathU8, &st) == 0;
}

static char *CreateFilenameWithNumber(const char *fullpathU8, int n)
{
	int FnPos;
	char Num[11];

	size_t len = strlen(fullpathU8) + sizeof(Num);
	char *new_name = (char *)malloc(len);

	GetFileNamePosU8(fullpathU8, NULL, &FnPos);

	snprintf(Num, sizeof(Num), "%u", n);
	size_t num_len = strlen(Num);

	const char *filename = &fullpathU8[FnPos];
	size_t filename_len = strlen(filename);
	const char *ext = strrchr(filename, '.');
	if (ext == NULL) {
		char *d = new_name;
		memcpy(d, fullpathU8, FnPos + filename_len);
		d += FnPos + filename_len;
		memcpy(d, Num, num_len);
		d += num_len;
		*d = 0;
	}
	else {
		size_t ext_len = strlen(ext);
		size_t base_len = filename_len - ext_len;
		char *d = new_name;
		memcpy(d, fullpathU8, FnPos + base_len);
		d += FnPos + base_len;
		memcpy(d, Num, num_len);
		d += num_len;
		memcpy(d, ext, ext_len);
		d += ext_len;
		*d = 0;
	}
	return new_name;
}

static char *CreateUniqueFilename(const char *fullpathU8)
{
	int i = 1;
	while (1) {
		char *filenameU8 = CreateFilenameWithNumber(fullpathU8, i);
		if (!DoesFileExist(filenameU8)) {
			return filenameU8;
		}
		free(filenameU8);
		i++;
	}
}

/* ttlib FitFileName() */
static void FitFileName(char *FileName, size_t destlen)
{
	size_t len = strlen(FileName);
	char *Temp = malloc(len + 2);
	size_t j = 0;
	if (FileName[0] == '.') {	/* filename started with a dot is illegal */
		Temp[j++] = '_';
	}
	memcpy(Temp + j, FileName, len + 1);
	if (j + len >= MAX_PATH) {
		Temp[MAX_PATH - 1] = 0;
	}
	strncpy_s(FileName, destlen, Temp, _TRUNCATE);
	free(Temp);
}

/* ttlib replaceInvalidFileNameCharU8(); same character set as Windows */
static char *ReplaceInvalidFileNameCharU8(const char *FName, char c)
{
	static const char invalid[] = "\\/:*?\"<>|";
	size_t len = strlen(FName);
	char *dest = malloc(len + 1);
	size_t j = 0;
	for (size_t i = 0; i < len; i++) {
		unsigned char ch = (unsigned char)FName[i];
		if (ch < ' ' || strchr(invalid, ch) != NULL) {
			if (c) dest[j++] = c;
		}
		else {
			dest[j++] = (char)ch;
		}
	}
	dest[j] = 0;
	return dest;
}

/* "ANSI" -> UTF-8: valid UTF-8 is kept, otherwise CP932 is assumed */
static char *AnsiToU8(const char *s)
{
	if (TeraFTIsValidUtf8(s)) {
		return strdup(s);
	}
	iconv_t cd = iconv_open("UTF-8", "CP932");
	if (cd == (iconv_t)-1) {
		return NULL;
	}
	size_t inlen = strlen(s);
	size_t outcap = inlen * 3 + 1;
	char *out = malloc(outcap);
	char *in = (char *)s;
	char *o = out;
	size_t outleft = outcap - 1;
	size_t r = iconv(cd, &in, &inlen, &o, &outleft);
	iconv_close(cd);
	if (r == (size_t)-1) {
		free(out);
		return NULL;
	}
	*o = 0;
	return out;
}

static char *GetReceiveFilename(struct FileIO *fv, const char *filename, BOOL utf8, const char *path, BOOL unique)
{
	(void)fv;
	char *new_name = NULL;
	if (!utf8) {
		int FnPos;
		GetFileNamePosU8(filename, NULL, &FnPos);
		new_name = AnsiToU8(&filename[FnPos]);
	}
	if (new_name == NULL) {
		int FnPos;
		GetFileNamePosU8(filename, NULL, &FnPos);
		new_name = strdup(&filename[FnPos]);
	}
	if (new_name == NULL) {
		return NULL;
	}
	size_t len = strlen(new_name) + 2;
	new_name = realloc(new_name, len);
	FitFileName(new_name, len);
	char *new_name_safe = ReplaceInvalidFileNameCharU8(new_name, '_');
	free(new_name);

	char *full;
	if (path == NULL) {
		full = strdup(new_name_safe);
	}
	else {
		size_t full_len = strlen(new_name_safe) + strlen(path) + 1;
		full = (char *)malloc(full_len);
		strcpy(full, path);
		strcat(full, new_name_safe);
	}
	free(new_name_safe);

	if (unique && DoesFileExist(full)) {
		char *f = CreateUniqueFilename(full);
		free(full);
		full = f;
	}
	return full;
}

static long GetFMtime(TFileIO *fv, const char *filenameU8)
{
	(void)fv;
	struct stat st;
	if (stat(filenameU8, &st) == -1) {
		return 0;
	}
	return (long)st.st_mtime;
}

static BOOL _SetFMtime(TFileIO *fv, const char *filenameU8, DWORD mtime)
{
	(void)fv;
	struct utimbuf filetime;
	filetime.actime = mtime;
	filetime.modtime = mtime;
	return utime(filenameU8, &filetime);
}

static void FileSysDestroy(TFileIO *fv)
{
	TFileIOPosix *data = (TFileIOPosix *)fv->data;
	fv->Close(fv);
	free(data);
	fv->data = NULL;
	free(fv);
}

TFileIO *TeraFTFilesysCreatePosix(void)
{
	TFileIOPosix *data = (TFileIOPosix *)calloc(1, sizeof(TFileIOPosix));
	if (data == NULL) {
		return NULL;
	}
	TFileIO *fv = (TFileIO *)calloc(1, sizeof(TFileIO));
	if (fv == NULL) {
		free(data);
		return NULL;
	}
	fv->data = data;
	fv->OpenRead = _OpenRead;
	fv->OpenWrite = _OpenWrite;
	fv->ReadFile = _ReadFile;
	fv->WriteFile = _WriteFile;
	fv->Close = _Close;
	fv->Seek = _Seek;
	fv->GetFSize = _GetFSize;
	fv->utime = _utime_;
	fv->stat = _stat_;
	fv->FileSysDestroy = FileSysDestroy;
	fv->GetSendFilename = GetSendFilename;
	fv->GetReceiveFilename = GetReceiveFilename;
	fv->GetFMtime = GetFMtime;
	fv->SetFMtime = _SetFMtime;
	return fv;
}
