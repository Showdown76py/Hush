#include "aec3_wrap.h"
#include "api/audio/audio_processing.h"
#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include <optional>

namespace {
// aec3 factory w/ custom config (missing from this distro of the lib)
class TunedFactory : public webrtc::EchoControlFactory {
 public:
  explicit TunedFactory(const webrtc::EchoCanceller3Config& c) : cfg_(c) {}
  std::unique_ptr<webrtc::EchoControl> Create(int sr, int render, int capture) override {
    return std::make_unique<webrtc::EchoCanceller3>(cfg_, std::nullopt, sr, render, capture);
  }
 private:
  webrtc::EchoCanceller3Config cfg_;
};

webrtc::EchoCanceller3Config ConfigFor(int preset) {
  webrtc::EchoCanceller3Config c;
  if (preset >= 1) {
    // more transparent masks, let more near-end signal (voice) through
    c.suppressor.normal_tuning.mask_lf.enr_transparent = preset == 1 ? .6f : 1.f;
    c.suppressor.normal_tuning.mask_lf.enr_suppress = preset == 1 ? .8f : 1.2f;
    c.suppressor.normal_tuning.mask_hf.enr_transparent = preset == 1 ? .2f : .4f;
    c.suppressor.normal_tuning.mask_hf.enr_suppress = preset == 1 ? .4f : .7f;
    // near-end voice detection faster and held longer
    c.suppressor.dominant_nearend_detection.enr_threshold = preset == 1 ? .1f : .05f;
    c.suppressor.dominant_nearend_detection.snr_threshold = preset == 1 ? 20.f : 12.f;
    c.suppressor.dominant_nearend_detection.trigger_threshold = preset == 1 ? 6 : 3;
    c.suppressor.dominant_nearend_detection.hold_duration = preset == 1 ? 100 : 150;
  }
  return c;
}
}  // namespace

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

extern "C" aec3_t *aec3_create_tuned(int ns, int preset, int agc) {
    auto *a = new aec3;
    a->apm = webrtc::AudioProcessingBuilder()
                 .SetEchoControlFactory(std::make_unique<TunedFactory>(ConfigFor(preset)))
                 .Create();
    webrtc::AudioProcessing::Config cfg;
    cfg.echo_canceller.enabled = true;
    cfg.echo_canceller.mobile_mode = false;
    cfg.high_pass_filter.enabled = true;
    cfg.noise_suppression.enabled = ns > 0;
    if (ns > 0) cfg.noise_suppression.level = static_cast<webrtc::AudioProcessing::Config::NoiseSuppression::Level>(ns - 1);
    cfg.gain_controller1.enabled = false;
    cfg.gain_controller2.enabled = agc != 0;
    cfg.gain_controller2.adaptive_digital.enabled = agc != 0;
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
    a->apm->set_stream_delay_ms(0);   // aec3 estimates delay itself
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
