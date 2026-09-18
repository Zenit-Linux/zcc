#define VERSION_MAJOR 1
#define VERSION_MINOR 2
#define CONCAT(a, b) a##b
#define STR(x) #x
#define MAX(a, b) ((a) > (b) ? (a) : (b))

#if VERSION_MAJOR >= 1 && defined(VERSION_MINOR)
const char *version = STR(CONCAT(VERSION_MAJOR, VERSION_MINOR));
#else
const char *version = "unknown";
#endif

#ifdef __ZCC__
int compiled_with_zcc = 1;
#endif

int biggest = MAX(3 + 4, 2 * 5);
