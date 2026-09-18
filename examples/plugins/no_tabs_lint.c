#include <string.h>

typedef struct {
    int kind;
    const char *text;
    int line;
    int col;
} ZccToken;

typedef struct {
    int line;
    int col;
    int isError;       /* 1 = error, 0 = warning */
    const char *message;
    const char *suggestion;
} ZccPluginDiag;

int zcc_plugin_abi_version(void) {
    return 1;
}

int zcc_plugin_check_tokens(const ZccToken *toks, int count,
                             ZccPluginDiag *out_diags, int max_diags) {
    int found = 0;
    for (int i = 0; i < count && found < max_diags; i++) {
        if (toks[i].text != NULL && strchr(toks[i].text, '\t') != NULL) {
            out_diags[found].line = toks[i].line;
            out_diags[found].col = toks[i].col;
            out_diags[found].isError = 0;
            out_diags[found].message = "token zawiera dosłowny znak tabulacji";
            out_diags[found].suggestion = "użyj spacji zamiast tabulacji wewnątrz literałów";
            found++;
        }
    }
    return found;
}
