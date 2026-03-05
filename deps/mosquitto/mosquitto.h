#ifndef MOSQUITTO_H
#define MOSQUITTO_H

#include <stddef.h>
#include <stdbool.h>

/* Opaque client handle */
struct mosquitto;

/* Callback types */
typedef void (*mosquitto_message_callback)(struct mosquitto *, void *, const struct mosquitto_message *);

/* Message struct */
struct mosquitto_message {
    int mid;
    char *topic;
    void *payload;
    int payloadlen;
    int qos;
    bool retain;
};

/* Error codes */
#define MOSQ_ERR_SUCCESS 0
#define MOSQ_ERR_ERRNO 14

/* Library lifecycle */
int mosquitto_lib_init(void);
int mosquitto_lib_cleanup(void);

/* Client lifecycle */
struct mosquitto *mosquitto_new(const char *id, bool clean_session, void *userdata);
void mosquitto_destroy(struct mosquitto *mosq);

/* Connection */
int mosquitto_connect(struct mosquitto *mosq, const char *host, int port, int keepalive);
int mosquitto_disconnect(struct mosquitto *mosq);

/* Pub/Sub */
int mosquitto_publish(struct mosquitto *mosq, int *mid, const char *topic,
                      int payloadlen, const void *payload, int qos, bool retain);
int mosquitto_subscribe(struct mosquitto *mosq, int *mid, const char *sub, int qos);

/* Network loop */
int mosquitto_loop_forever(struct mosquitto *mosq, int timeout, int max_packets);
int mosquitto_loop_start(struct mosquitto *mosq);
int mosquitto_loop_stop(struct mosquitto *mosq, bool force);

/* Callbacks */
void mosquitto_message_callback_set(struct mosquitto *mosq, mosquitto_message_callback on_message);

#endif
