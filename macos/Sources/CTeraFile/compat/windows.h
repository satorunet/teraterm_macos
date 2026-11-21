/*
 * Tera Term Mac: minimal <windows.h> replacement for compiling Tera Term's
 * portable file-transfer protocol sources (ttpfile/ *.c) on macOS.
 * Only the types, macros and functions those sources actually use are defined.
 */
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <wchar.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <utime.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int BOOL;
typedef uint8_t BYTE;
typedef uint16_t WORD;
typedef uint32_t DWORD;
typedef int32_t LONG;          /* Win32 LONG is always 32 bit */
typedef int64_t LONGLONG;
typedef unsigned int UINT;
typedef char CHAR;
typedef char *PCHAR;
typedef char *LPSTR;
typedef const char *LPCSTR;
typedef BYTE *LPBYTE;
typedef BYTE *PBYTE;
typedef WORD *LPWORD;
typedef LONG *LPLONG;
typedef LONG *PLONG;
typedef DWORD *LPDWORD;
typedef void *HWND;
typedef void *HANDLE;
typedef uintptr_t UINT_PTR;
typedef intptr_t LONG_PTR;

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

#ifndef MAX_PATH
#define MAX_PATH 260
#endif

#define _TRUNCATE ((size_t)-1)
#ifndef _countof
#define _countof(a) (sizeof(a) / sizeof((a)[0]))
#endif

#define LOBYTE(w) ((BYTE)(((uintptr_t)(w)) & 0xff))
#define HIBYTE(w) ((BYTE)((((uintptr_t)(w)) >> 8) & 0xff))
#define LOWORD(l) ((WORD)(((uintptr_t)(l)) & 0xffff))
#define HIWORD(l) ((WORD)((((uintptr_t)(l)) >> 16) & 0xffff))
#define MAKELONG(a, b) ((LONG)(((WORD)(((uintptr_t)(a)) & 0xffff)) | ((DWORD)((WORD)(((uintptr_t)(b)) & 0xffff))) << 16))

#define MB_OK              0x00000000
#define MB_ICONHAND        0x00000010
#define MB_ICONERROR       MB_ICONHAND
#define MB_ICONSTOP        MB_ICONHAND
#define MB_ICONEXCLAMATION 0x00000030
#define MB_ICONWARNING     MB_ICONEXCLAMATION
#define MB_TASKMODAL       0x00002000

/* MSVC CRT names */
#define _stati64 stat
#define _S_IFREG S_IFREG
#define _strdup strdup
#define _stricmp strcasecmp
#define sscanf_s sscanf

DWORD GetTickCount(void);
int MessageBoxA(HWND hWnd, const char *text, const char *caption, UINT type);
#define MessageBox MessageBoxA
UINT_PTR SetTimer(HWND hWnd, UINT_PTR id, UINT elapse_ms, void *func);
BOOL KillTimer(HWND hWnd, UINT_PTR id);

int strncpy_s(char *dst, size_t dstsize, const char *src, size_t count);
int strncat_s(char *dst, size_t dstsize, const char *src, size_t count);
int _snprintf_s(char *buf, size_t size, size_t count, const char *fmt, ...);
int _vsnprintf_s(char *buf, size_t size, size_t count, const char *fmt, va_list ap);
int memmove_s(void *dst, size_t dstsize, const void *src, size_t count);
int ctime_s(char *buf, size_t size, const time_t *t);
int localtime_s(struct tm *tm, const time_t *t);
LONGLONG _atoi64(const char *s);

#ifdef __cplusplus
}
#endif
