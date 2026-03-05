#include "mosquitto.h"
#include <stdlib.h>
#include <string.h>

struct mosquitto {
    void *userdata;
    mosquitto_message_callback on_message;
    int connected;
};

int mosquitto_lib_init(void) { return MOSQ_ERR_SUCCESS; }
int mosquitto_lib_cleanup(void) { return MOSQ_ERR_SUCCESS; }

struct mosquitto *mosquitto_new(const char *id, bool clean_session, void *userdata) {
    (void)id;
    (void)clean_session;
    struct mosquitto *m = calloc(1, sizeof(struct mosquitto));
    if (m) m->userdata = userdata;
    return m;
}

void mosquitto_destroy(struct mosquitto *mosq) { if (mosq) free(mosq); }

int mosquitto_connect(struct mosquitto *mosq, const char *host, int port, int keepalive) {
    (void)mosq; (void)host; (void)port; (void)keepalive;
    return MOSQ_ERR_SUCCESS;
}

int mosquitto_disconnect(struct mosquitto *mosq) {
    (void)mosq;
    return MOSQ_ERR_SUCCESS;
}

int mosquitto_publish(struct mosquitto *mosq, int *mid, const char *topic,
                      int payloadlen, const void *payload, int qos, bool retain) {
    (void)mosq; (void)mid; (void)topic; (void)payloadlen;
    (void)payload; (void)qos; (void)retain;
    return MOSQ_ERR_SUCCESS;
}

int mosquitto_subscribe(struct mosquitto *mosq, int *mid, const char *sub, int qos) {
    (void)mosq; (void)mid; (void)sub; (void)qos;
    return MOSQ_ERR_SUCCESS;
}

int mosquitto_loop_forever(struct mosquitto *mosq, int timeout, int max_packets) {
    (void)mosq; (void)timeout; (void)max_packets;
    return MOSQ_ERR_SUCCESS;
}

int mosquitto_loop_start(struct mosquitto *mosq) { (void)mosq; return MOSQ_ERR_SUCCESS; }
int mosquitto_loop_stop(struct mosquitto *mosq, bool force) { (void)mosq; (void)force; return MOSQ_ERR_SUCCESS; }

void mosquitto_message_callback_set(struct mosquitto *mosq, mosquitto_message_callback on_message) {
    if (mosq) mosq->on_message = on_message;
}
