/* Tera Term Mac: replacement for common/asprintf.h (only what protolog.cpp uses) */
#pragma once
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
/* MSVC wide printf semantics: "%s" is a wide string */
int aswprintf(wchar_t **strp, const wchar_t *fmt, ...);
#ifdef __cplusplus
}
#endif
