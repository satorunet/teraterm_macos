/*
 * Tera Term Mac: POSIX implementations of the Win32 / MSVC CRT functions used
 * by Tera Term's file-transfer protocol sources (ttpfile/).
 *
 * (C) 2026 Tera Term Mac. Same license as Tera Term (BSD 3-Clause), see LICENSE.
 */
#include <windows.h>
#include <tttypes.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>
#include <mach/mach_time.h>

#include "codeconv.h"
#include "asprintf.h"
#include "ttlib.h"
#include "teraft_internal.h"

DWORD GetTickCount(void)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	uint64_t ns = mach_absolute_time() * tb.numer / tb.denom;
	return (DWORD)(ns / 1000000ULL);
}

/* ------------------------------------------------------------------ */
/* MSVC secure string functions (only _TRUNCATE semantics are needed)  */

int strncpy_s(char *dst, size_t dstsize, const char *src, size_t count)
{
	if (dst == NULL || dstsize == 0) {
		return EINVAL;
	}
	if (src == NULL) {
		dst[0] = 0;
		return EINVAL;
	}
	size_t len = strlen(src);
	if (count != _TRUNCATE && count < len) {
		len = count;
	}
	if (len >= dstsize) {
		len = dstsize - 1;	/* truncate */
	}
	memmove(dst, src, len);
	dst[len] = 0;
	return 0;
}

int strncat_s(char *dst, size_t dstsize, const char *src, size_t count)
{
	if (dst == NULL || dstsize == 0) {
		return EINVAL;
	}
	size_t cur = strnlen(dst, dstsize);
	if (cur >= dstsize) {
		dst[0] = 0;
		return EINVAL;
	}
	return strncpy_s(dst + cur, dstsize - cur, src, count);
}

/*
 * Windows is LLP64: "long" is 32 bit there.  The protocol sources pass
 * LONG/DWORD (32 bit) values with "%ld" / "%lu" / "%lo", and 64 bit values
 * with "%I64d".  Rewrite the format to the LP64 equivalents so the varargs are
 * read with the right width.
 */
static char *ConvertMsFormat(const char *fmt, char *local, size_t localsize)
{
	size_t need = strlen(fmt) * 2 + 1;
	char *out = need <= localsize ? local : malloc(need);
	if (out == NULL) {
		return NULL;
	}
	const char *s = fmt;
	char *d = out;
	while (*s) {
		if (*s != '%') {
			*d++ = *s++;
			continue;
		}
		*d++ = *s++;
		if (*s == '%') {
			*d++ = *s++;
			continue;
		}
		/* flags, width, precision */
		while (*s && strchr("-+ #0123456789.*", *s) != NULL) {
			*d++ = *s++;
		}
		if (s[0] == 'I' && s[1] == '6' && s[2] == '4') {
			*d++ = 'l';
			*d++ = 'l';
			s += 3;
		}
		else if (s[0] == 'l' && s[1] == 'l') {
			*d++ = *s++;
			*d++ = *s++;
		}
		else if (s[0] == 'l' && s[1] != 0 && strchr("diouxX", s[1]) != NULL) {
			s++;	/* drop 'l': MSVC long == int */
		}
		else if (s[0] == 'I' && s[1] == '3' && s[2] == '2') {
			s += 3;
		}
	}
	*d = 0;
	return out;
}

int _vsnprintf_s(char *buf, size_t size, size_t count, const char *fmt, va_list ap)
{
	if (buf == NULL || size == 0) {
		return -1;
	}
	char local[512];
	char *f = ConvertMsFormat(fmt, local, sizeof(local));
	if (f == NULL) {
		buf[0] = 0;
		return -1;
	}
	size_t limit = size;
	if (count != _TRUNCATE && count + 1 < limit) {
		limit = count + 1;
	}
	int r = vsnprintf(buf, limit, f, ap);
	if (f != local) {
		free(f);
	}
	if (r < 0) {
		buf[0] = 0;
		return -1;
	}
	if ((size_t)r >= limit) {
		/* truncated: MSVC returns -1 */
		return -1;
	}
	return r;
}

int _snprintf_s(char *buf, size_t size, size_t count, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int r = _vsnprintf_s(buf, size, count, fmt, ap);
	va_end(ap);
	return r;
}

int memmove_s(void *dst, size_t dstsize, const void *src, size_t count)
{
	if (count > dstsize) {
		return ERANGE;
	}
	memmove(dst, src, count);
	return 0;
}

int ctime_s(char *buf, size_t size, const time_t *t)
{
	char tmp[64];
	if (ctime_r(t, tmp) == NULL) {
		if (size > 0) buf[0] = 0;
		return EINVAL;
	}
	strncpy_s(buf, size, tmp, _TRUNCATE);
	return 0;
}

int localtime_s(struct tm *tm, const time_t *t)
{
	return localtime_r(t, tm) == NULL ? EINVAL : 0;
}

LONGLONG _atoi64(const char *s)
{
	return (LONGLONG)strtoll(s, NULL, 10);
}

/* ------------------------------------------------------------------ */
/* UI: message boxes are not shown (macro use / no dialog).            */

int MessageBoxA(HWND hWnd, const char *text, const char *caption, UINT type)
{
	(void)hWnd; (void)type;
	TeraFTReportMessage(caption, text);
	return 1;	/* IDOK */
}

int TTMessageBoxW(HWND hWnd, const TTMessageBoxInfoW *info, const wchar_t *UILanguageFile, ...)
{
	(void)hWnd; (void)UILanguageFile;
	char *title = ToU8W(info->title_default);
	char *msg = ToU8W(info->message_default);
	TeraFTReportMessage(title, msg);
	free(title);
	free(msg);
	return 1;
}

/* ------------------------------------------------------------------ */
/* Character conversion (wchar_t is UTF-32 on macOS)                   */

static size_t DecodeUtf8(const unsigned char *s, uint32_t *cp)
{
	unsigned char c = s[0];
	if (c < 0x80) { *cp = c; return 1; }
	int n;
	uint32_t v;
	if ((c & 0xe0) == 0xc0) { n = 2; v = c & 0x1f; }
	else if ((c & 0xf0) == 0xe0) { n = 3; v = c & 0x0f; }
	else if ((c & 0xf8) == 0xf0) { n = 4; v = c & 0x07; }
	else return 0;
	for (int i = 1; i < n; i++) {
		if ((s[i] & 0xc0) != 0x80) return 0;
		v = (v << 6) | (s[i] & 0x3f);
	}
	if ((n == 2 && v < 0x80) || (n == 3 && v < 0x800) || (n == 4 && (v < 0x10000 || v > 0x10ffff)) ||
		(v >= 0xd800 && v <= 0xdfff)) {
		return 0;
	}
	*cp = v;
	return (size_t)n;
}

BOOL TeraFTIsValidUtf8(const char *s)
{
	const unsigned char *p = (const unsigned char *)s;
	while (*p) {
		uint32_t cp;
		size_t n = DecodeUtf8(p, &cp);
		if (n == 0) return FALSE;
		p += n;
	}
	return TRUE;
}

wchar_t *ToWcharU8(const char *strU8)
{
	if (strU8 == NULL) return NULL;
	size_t len = strlen(strU8);
	wchar_t *w = malloc(sizeof(wchar_t) * (len + 1));
	if (w == NULL) return NULL;
	const unsigned char *p = (const unsigned char *)strU8;
	size_t j = 0;
	while (*p) {
		uint32_t cp;
		size_t n = DecodeUtf8(p, &cp);
		if (n == 0) {
			free(w);
			return NULL;	/* not UTF-8 (same as the Windows version) */
		}
		w[j++] = (wchar_t)cp;
		p += n;
	}
	w[j] = 0;
	return w;
}

wchar_t *ToWcharA(const char *strA)
{
	/* macOS has no "ANSI" code page; UTF-8, falling back to Latin-1 */
	wchar_t *w = ToWcharU8(strA);
	if (w != NULL || strA == NULL) return w;
	size_t len = strlen(strA);
	w = malloc(sizeof(wchar_t) * (len + 1));
	if (w == NULL) return NULL;
	for (size_t i = 0; i <= len; i++) w[i] = (unsigned char)strA[i];
	return w;
}

char *ToU8W(const wchar_t *strW)
{
	if (strW == NULL) return NULL;
	size_t len = wcslen(strW);
	char *s = malloc(len * 4 + 1);
	if (s == NULL) return NULL;
	char *d = s;
	for (size_t i = 0; i < len; i++) {
		uint32_t c = (uint32_t)strW[i];
		if (c < 0x80) { *d++ = (char)c; }
		else if (c < 0x800) { *d++ = (char)(0xc0 | (c >> 6)); *d++ = (char)(0x80 | (c & 0x3f)); }
		else if (c < 0x10000) { *d++ = (char)(0xe0 | (c >> 12)); *d++ = (char)(0x80 | ((c >> 6) & 0x3f)); *d++ = (char)(0x80 | (c & 0x3f)); }
		else { *d++ = (char)(0xf0 | (c >> 18)); *d++ = (char)(0x80 | ((c >> 12) & 0x3f)); *d++ = (char)(0x80 | ((c >> 6) & 0x3f)); *d++ = (char)(0x80 | (c & 0x3f)); }
	}
	*d = 0;
	return s;
}

wchar_t *_wcsdup(const wchar_t *s)
{
	size_t len = wcslen(s) + 1;
	wchar_t *d = malloc(len * sizeof(wchar_t));
	if (d != NULL) memcpy(d, s, len * sizeof(wchar_t));
	return d;
}

/* Windows path -> POSIX path: '\\' is a separator in paths built by Tera Term */
int _wfopen_s(FILE **fp, const wchar_t *filename, const wchar_t *mode)
{
	char *f = ToU8W(filename);
	char *m = ToU8W(mode);
	if (f == NULL || m == NULL) {
		free(f); free(m);
		*fp = NULL;
		return EINVAL;
	}
	for (char *p = f; *p; p++) {
		if (*p == '\\') *p = '/';
	}
	*fp = fopen(f, m);
	int err = *fp == NULL ? errno : 0;
	free(f);
	free(m);
	return err;
}

/*
 * aswprintf() with MSVC wide-printf semantics ("%s" = wide string).
 * Rewrites "%s" to "%ls" and formats with vswprintf.
 */
int aswprintf(wchar_t **strp, const wchar_t *fmt, ...)
{
	size_t flen = wcslen(fmt);
	wchar_t *f = malloc(sizeof(wchar_t) * (flen * 2 + 1));
	if (f == NULL) { *strp = NULL; return -1; }
	size_t j = 0;
	for (size_t i = 0; i < flen; i++) {
		f[j++] = fmt[i];
		if (fmt[i] == L'%') {
			if (fmt[i + 1] == L'%') { f[j++] = fmt[++i]; continue; }
			while (i + 1 < flen && wcschr(L"-+ #0123456789.*", fmt[i + 1]) != NULL) f[j++] = fmt[++i];
			if (fmt[i + 1] == L's') f[j++] = L'l';
		}
	}
	f[j] = 0;
	size_t cap = 256;
	for (;;) {
		wchar_t *buf = malloc(sizeof(wchar_t) * cap);
		if (buf == NULL) { free(f); *strp = NULL; return -1; }
		va_list ap;
		va_start(ap, fmt);
		int r = vswprintf(buf, cap, f, ap);
		va_end(ap);
		if (r >= 0 && (size_t)r < cap) {
			free(f);
			*strp = buf;
			return r;
		}
		free(buf);
		cap *= 2;
		if (cap > 1024 * 1024) { free(f); *strp = NULL; return -1; }
	}
}
