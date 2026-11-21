/* Tera Term Mac: internal helpers shared by the glue sources */
#pragma once
#include <windows.h>
#include "filesys_io.h"

#ifdef __cplusplus
extern "C" {
#endif
TFileIO *TeraFTFilesysCreatePosix(void);
BOOL TeraFTIsValidUtf8(const char *s);
void TeraFTReportMessage(const char *caption, const char *text);
#ifdef __cplusplus
}
#endif
