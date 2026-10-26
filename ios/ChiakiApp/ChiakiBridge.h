// Thin C layer over chiaki-lib so Swift doesn't have to deal with its
// fixed-size arrays and unions. Same role as android/.../chiaki-jni.c.

#ifndef CHIAKI_BRIDGE_H
#define CHIAKI_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CB_KEY_SIZE 16
#define CB_PSN_ACCOUNT_ID_SIZE 8

typedef void (*CBLogCb)(int level, const char *msg);
// regist_key/morning are CB_KEY_SIZE bytes, all NULL on failure
typedef void (*CBRegistCb)(bool ok, const uint8_t *regist_key, const uint8_t *morning, const char *nickname, void *user);
// Annex-B H.264 access unit. Return false to request a new keyframe.
typedef bool (*CBVideoCb)(const uint8_t *buf, size_t len, void *user);

typedef enum {
	CB_EVENT_CONNECTED,
	CB_EVENT_LOGIN_PIN_REQUEST,
	CB_EVENT_QUIT
} CBEventType;
// msg is only set for CB_EVENT_QUIT
typedef void (*CBEventCb)(CBEventType type, const char *msg, void *user);

typedef struct cb_regist_t CBRegist;
typedef struct cb_session_t CBSession;

int cb_init(CBLogCb log_cb);

CBRegist *cb_regist_start(const char *host, bool ps5, const uint8_t *psn_account_id, uint32_t pin, CBRegistCb cb, void *user);
// Must not be called from inside the regist callback
void cb_regist_free(CBRegist *regist);

CBSession *cb_session_start(const char *host, bool ps5, const uint8_t *regist_key, const uint8_t *morning,
		CBVideoCb video_cb, CBEventCb event_cb, void *user);
void cb_session_set_controller(CBSession *session, uint32_t buttons, uint8_t l2, uint8_t r2,
		int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y);
void cb_session_set_login_pin(CBSession *session, const char *pin);
// Stops, joins and frees. Must not be called from inside a session callback
void cb_session_free(CBSession *session);

#endif
