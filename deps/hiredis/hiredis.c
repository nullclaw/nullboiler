#include "hiredis.h"
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

redisContext *redisConnect(const char *ip, int port) {
    redisContext *c = calloc(1, sizeof(redisContext));
    if (!c) return NULL;
    c->err = 0;
    c->fd = -1;
    (void)ip;
    (void)port;
    return c;
}

void redisFree(redisContext *c) {
    if (c) free(c);
}

void freeReplyObject(void *reply) {
    if (reply) free(reply);
}

void *redisCommand(redisContext *c, const char *format, ...) {
    (void)c;
    (void)format;
    return NULL;
}
