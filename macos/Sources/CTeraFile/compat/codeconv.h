/* Tera Term Mac: replacement for common/codeconv.h (only what protolog.cpp uses) */
#pragma once
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
wchar_t *ToWcharA(const char *strA);    /* "ANSI" is treated as UTF-8 on macOS */
wchar_t *ToWcharU8(const char *strU8);
char *ToU8W(const wchar_t *strW);
#ifdef __cplusplus
}
#endif
