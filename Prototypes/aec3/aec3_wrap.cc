#include "aec3_wrap.h"
#include "api/audio/audio_processing.h"

struct aec3 {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
};

extern "C" aec3_t *aec3_create(int ns) {
    auto *a = new aec3;
    a->apm = webrtc::AudioProcessingBuilder().Create();
    webrtc::AudioProcessing::Config cfg;
    cfg.echo_canceller.enabled = true;
    cfg.echo_canceller.mobile_mode = false;
    cfg.high_pass_filter.enabled = true;
    cfg.noise_suppression.enabled = ns > 0;
    if (ns > 0) cfg.noise_suppression.level = static_cast<webrtc::AudioProcessing::Config::NoiseSuppression::Level>(ns - 1);
    cfg.gain_controller1.enabled = false;
    cfg.gain_controller2.enabled = false;
    a->apm->ApplyConfig(cfg);
    return a;
}

extern "C" void aec3_destroy(aec3_t *a) { delete a; }

extern "C" int aec3_process(aec3_t *a, const float *ref, const float *mic, float *out) {
    webrtc::StreamConfig sc(48000, 1);
    float refCopy[480];
    const float *r[1] = {ref};
    float *ro[1] = {refCopy};
    int e = a->apm->ProcessReverseStream(r, sc, sc, ro);
    if (e) return e;
    a->apm->set_stream_delay_ms(0);   // AEC3 estime le retard lui-même
    const float *m[1] = {mic};
    float *o[1] = {out};
    return a->apm->ProcessStream(m, sc, sc, o);
}

extern "C" int aec3_delay_ms(aec3_t *a) {
    auto s = a->apm->GetStatistics();
    return s.delay_ms ? *s.delay_ms : -1;
}

extern "C" float aec3_erle_db(aec3_t *a) {
    auto s = a->apm->GetStatistics();
    return s.echo_return_loss_enhancement ? static_cast<float>(*s.echo_return_loss_enhancement) : 0.f;
}
