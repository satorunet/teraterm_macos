// アプリの中の SSH。libssh2 (BSD 3-Clause) を OpenSSL 3 (Apache 2.0) と組み立てたものを使う (scripts/build-ssh-libs.sh)
#include "libssh2.h"
#include <stdlib.h>
#include <string.h>

/// keyboard-interactive の返事を libssh2 に渡す (text は malloc したもの。libssh2 が free する)
static inline void cssh2_set_response(LIBSSH2_USERAUTH_KBDINT_RESPONSE *r, int i, const char *s) {
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    memcpy(p, s, n + 1);
    r[i].text = p;
    r[i].length = (unsigned int)n;
}
