#include "ChiakiBridge.h"

#include <chiaki/session.h>
#include <chiaki/regist.h>
#include <chiaki/controller.h>

#include <stdlib.h>
#include <string.h>

static CBLogCb g_log_cb;
static ChiakiLog g_log;

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(g_log_cb)
		g_log_cb((int)level, msg);
}

int cb_init(CBLogCb log_cb_fn)
{
	g_log_cb = log_cb_fn;
	chiaki_log_init(&g_log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, log_cb, NULL);
	return chiaki_lib_init();
}

struct cb_regist_t
{
	ChiakiRegist regist;
	CBRegistCb cb;
	void *user;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	CBRegist *r = user;
	if(event->type != CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS)
	{
		r->cb(false, NULL, NULL, NULL, r->user);
		return;
	}
	ChiakiRegisteredHost *host = event->registered_host;
	char nickname[sizeof(host->server_nickname) + 1] = { 0 };
	memcpy(nickname, host->server_nickname, sizeof(host->server_nickname));
	r->cb(true, (const uint8_t *)host->rp_regist_key, host->rp_key, nickname, r->user);
}

CBRegist *cb_regist_start(const char *host, bool ps5, const uint8_t *psn_account_id, uint32_t pin, CBRegistCb cb, void *user)
{
	CBRegist *r = calloc(1, sizeof(CBRegist));
	if(!r)
		return NULL;
	r->cb = cb;
	r->user = user;

	ChiakiRegistInfo info = { 0 };
	info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
	info.host = host; // copied by chiaki_regist_start
	memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;

	if(chiaki_regist_start(&r->regist, &g_log, &info, regist_cb, r) != CHIAKI_ERR_SUCCESS)
	{
		free(r);
		return NULL;
	}
	return r;
}

void cb_regist_free(CBRegist *r)
{
	chiaki_regist_stop(&r->regist);
	chiaki_regist_fini(&r->regist);
	free(r);
}

struct cb_session_t
{
	ChiakiSession session;
	CBVideoCb video_cb;
	CBEventCb event_cb;
	void *user;
};

static bool video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frames_lost;
	(void)frame_recovered;
	CBSession *s = user;
	return s->video_cb(buf, buf_size, s->user);
}

static void event_cb(ChiakiEvent *event, void *user)
{
	CBSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			s->event_cb(CB_EVENT_CONNECTED, NULL, s->user);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			s->event_cb(CB_EVENT_LOGIN_PIN_REQUEST, NULL, s->user);
			break;
		case CHIAKI_EVENT_QUIT:
			s->event_cb(CB_EVENT_QUIT, event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason), s->user);
			break;
		default:
			break;
	}
}

CBSession *cb_session_start(const char *host, bool ps5, const uint8_t *regist_key, const uint8_t *morning,
		CBVideoCb video_cb_fn, CBEventCb event_cb_fn, void *user)
{
	CBSession *s = calloc(1, sizeof(CBSession));
	if(!s)
		return NULL;
	s->video_cb = video_cb_fn;
	s->event_cb = event_cb_fn;
	s->user = user;

	ChiakiConnectInfo info = { 0 };
	info.ps5 = ps5;
	info.host = host; // resolved inside chiaki_session_init
	memcpy(info.regist_key, regist_key, sizeof(info.regist_key));
	memcpy(info.morning, morning, sizeof(info.morning));
	// ponytail: fixed 720p60 H.264, add a settings screen + HEVC when the basics work
	chiaki_connect_video_profile_preset(&info.video_profile, CHIAKI_VIDEO_RESOLUTION_PRESET_720p, CHIAKI_VIDEO_FPS_PRESET_60);
	info.video_profile.codec = CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_dualsense = true;
	info.packet_loss_max = 0.05; // same default as the Qt GUI
	info.enable_idr_on_fec_failure = true;

	if(chiaki_session_init(&s->session, &info, &g_log) != CHIAKI_ERR_SUCCESS)
	{
		free(s);
		return NULL;
	}
	chiaki_session_set_event_cb(&s->session, event_cb, s);
	chiaki_session_set_video_sample_cb(&s->session, video_cb, s);

	if(chiaki_session_start(&s->session) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_session_fini(&s->session);
		free(s);
		return NULL;
	}
	return s;
}

void cb_session_set_controller(CBSession *s, uint32_t buttons, uint8_t l2, uint8_t r2,
		int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y)
{
	ChiakiControllerState state;
	chiaki_controller_state_set_idle(&state);
	state.buttons = buttons;
	state.l2_state = l2;
	state.r2_state = r2;
	state.left_x = left_x;
	state.left_y = left_y;
	state.right_x = right_x;
	state.right_y = right_y;
	chiaki_session_set_controller_state(&s->session, &state);
}

void cb_session_set_login_pin(CBSession *s, const char *pin)
{
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void cb_session_free(CBSession *s)
{
	chiaki_session_stop(&s->session);
	chiaki_session_join(&s->session);
	chiaki_session_fini(&s->session);
	free(s);
}
