/* Tera Term Mac: Swift から鬼車の文字コード・文法を選ぶための小さな関数 */
#ifndef TERAMAC_ONIG_H
#define TERAMAC_ONIG_H
#include "oniguruma.h"

/* 名前 (ttl.cpp の regexoption と同じ: "UTF8", "SJIS" など) から文字コード。なければ NULL */
OnigEncoding teramac_onig_encoding(const char *name);
/* 名前 ("RUBY", "PERL", "DEFAULT" など) から文法。なければ NULL */
OnigSyntaxType *teramac_onig_syntax(const char *name);
/* onig_error_code_to_str の可変引数を使わない版 */
int teramac_onig_error_string(unsigned char *buf, int code, OnigErrorInfo *einfo);
#endif
