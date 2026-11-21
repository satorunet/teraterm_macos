/* Tera Term Mac: replacement for common/ttlib.h (only what protolog.cpp uses) */
#pragma once
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
wchar_t *_wcsdup(const wchar_t *s);
int _wfopen_s(FILE **fp, const wchar_t *filename, const wchar_t *mode);
#ifdef __cplusplus
}
#endif
