#include <string.h>
#include <strings.h>
#include "teramac_onig.h"

OnigEncoding teramac_onig_encoding(const char *n)
{
	static const struct { const char *name; OnigEncoding enc; } t[] = {
		{"ASCII", ONIG_ENCODING_ASCII}, {"ISO_8859_1", ONIG_ENCODING_ISO_8859_1}, {"ISO_8859_2", ONIG_ENCODING_ISO_8859_2},
		{"ISO_8859_3", ONIG_ENCODING_ISO_8859_3}, {"ISO_8859_4", ONIG_ENCODING_ISO_8859_4}, {"ISO_8859_5", ONIG_ENCODING_ISO_8859_5},
		{"ISO_8859_6", ONIG_ENCODING_ISO_8859_6}, {"ISO_8859_7", ONIG_ENCODING_ISO_8859_7}, {"ISO_8859_8", ONIG_ENCODING_ISO_8859_8},
		{"ISO_8859_9", ONIG_ENCODING_ISO_8859_9}, {"ISO_8859_10", ONIG_ENCODING_ISO_8859_10}, {"ISO_8859_11", ONIG_ENCODING_ISO_8859_11},
		{"ISO_8859_13", ONIG_ENCODING_ISO_8859_13}, {"ISO_8859_14", ONIG_ENCODING_ISO_8859_14}, {"ISO_8859_15", ONIG_ENCODING_ISO_8859_15},
		{"ISO_8859_16", ONIG_ENCODING_ISO_8859_16}, {"UTF8", ONIG_ENCODING_UTF8}, {"UTF16_BE", ONIG_ENCODING_UTF16_BE},
		{"UTF16_LE", ONIG_ENCODING_UTF16_LE}, {"UTF32_BE", ONIG_ENCODING_UTF32_BE}, {"UTF32_LE", ONIG_ENCODING_UTF32_LE},
		{"EUC_JP", ONIG_ENCODING_EUC_JP}, {"EUC_TW", ONIG_ENCODING_EUC_TW}, {"EUC_KR", ONIG_ENCODING_EUC_KR},
		{"EUC_CN", ONIG_ENCODING_EUC_CN}, {"SJIS", ONIG_ENCODING_SJIS}, {"CP932", ONIG_ENCODING_SJIS},
		{"KOI8_R", ONIG_ENCODING_KOI8_R}, {"CP1251", ONIG_ENCODING_CP1251}, {"BIG5", ONIG_ENCODING_BIG5},
		{"GB18030", ONIG_ENCODING_GB18030},
	};
	size_t i;
	for (i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
		if (strcasecmp(n, t[i].name) == 0) return t[i].enc;
	}
	return NULL;
}

OnigSyntaxType *teramac_onig_syntax(const char *n)
{
	if (strcasecmp(n, "DEFAULT") == 0) return ONIG_SYNTAX_DEFAULT;
	if (strcasecmp(n, "ASIS") == 0) return ONIG_SYNTAX_ASIS;
	if (strcasecmp(n, "POSIX_BASIC") == 0) return ONIG_SYNTAX_POSIX_BASIC;
	if (strcasecmp(n, "POSIX_EXTENDED") == 0) return ONIG_SYNTAX_POSIX_EXTENDED;
	if (strcasecmp(n, "EMACS") == 0) return ONIG_SYNTAX_EMACS;
	if (strcasecmp(n, "GREP") == 0) return ONIG_SYNTAX_GREP;
	if (strcasecmp(n, "GNU_REGEX") == 0) return ONIG_SYNTAX_GNU_REGEX;
	if (strcasecmp(n, "JAVA") == 0) return ONIG_SYNTAX_JAVA;
	if (strcasecmp(n, "PERL") == 0) return ONIG_SYNTAX_PERL;
	if (strcasecmp(n, "PERL_NG") == 0) return ONIG_SYNTAX_PERL_NG;
	if (strcasecmp(n, "RUBY") == 0) return ONIG_SYNTAX_RUBY;
	return NULL;
}

int teramac_onig_error_string(unsigned char *buf, int code, OnigErrorInfo *einfo)
{
	return onig_error_code_to_str(buf, code, einfo);
}
