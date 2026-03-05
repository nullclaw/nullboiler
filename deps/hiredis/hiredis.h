#ifndef HIREDIS_H
#define HIREDIS_H

#include <stddef.h>

/* Connection */
typedef struct redisContext {
    int err;
    char errstr[128];
    int fd;
} redisContext;

/* Reply */
typedef struct redisReply {
    int type;
    long long integer;
    size_t len;
    char *str;
    size_t elements;
    struct redisReply **element;
} redisReply;

/* Reply types */
#define REDIS_REPLY_STRING 1
#define REDIS_REPLY_ARRAY 2
#define REDIS_REPLY_INTEGER 3
#define REDIS_REPLY_NIL 4
#define REDIS_REPLY_STATUS 5
#define REDIS_REPLY_ERROR 6

/* Functions */
redisContext *redisConnect(const char *ip, int port);
void redisFree(redisContext *c);
void freeReplyObject(void *reply);
void *redisCommand(redisContext *c, const char *format, ...);

#endif
