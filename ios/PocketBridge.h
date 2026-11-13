#include <stdlib.h>
// Returned strings belong to the caller and must be released with PocketFree.
char *PocketStart(const char *stateDir, const char *controlURL);
char *PocketStatus(void);
char *PocketForward(const char *targetURL);
void PocketStop(void);
void PocketFree(char *value);
