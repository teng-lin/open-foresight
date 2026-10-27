#include "pcm_output.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <chrono>
#include <thread>
#include <vector>
namespace foresight {
namespace {
AudioDeviceID device_for_uid(const std::string &uid) {
  AudioObjectPropertyAddress property{kAudioHardwarePropertyDevices,
                                      kAudioObjectPropertyScopeGlobal,
                                      kAudioObjectPropertyElementMain};
  UInt32 bytes = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0,
                                     nullptr, &bytes) != noErr)
    throw std::runtime_error("output_device_unavailable");
  std::vector<AudioDeviceID> devices(bytes / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0,
                                 nullptr, &bytes, devices.data()) != noErr)
    throw std::runtime_error("output_device_unavailable");
  for (auto device : devices) {
    property = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain};
    CFStringRef name = nullptr;
    bytes = sizeof(name);
    if (AudioObjectGetPropertyData(device, &property, 0, nullptr, &bytes,
                                   &name) != noErr ||
        !name)
      continue;
    const auto match = [(__bridge NSString *)name
        isEqualToString:[NSString stringWithUTF8String:uid.c_str()]];
    CFRelease(name);
    if (match)
      return device;
  }
  throw std::runtime_error("output_device_unavailable");
}
class MacPcmOutput final : public PcmOutputBackend {
  PcmOutput &owner_;
  const std::string target_;
  const bool offline_;
  AVAudioEngine *__strong engine_ = nil;
  AVAudioSourceNode *__strong source_ = nil;
  struct RenderGate {
    std::atomic<PcmOutput *> owner{nullptr};
    std::atomic<uint32_t> callbacks{0};
  };
  std::shared_ptr<RenderGate> render_ = std::make_shared<RenderGate>();
  id __strong observer_ = nil;
  struct NotificationGate {
    std::mutex mutex;
    PcmOutput *owner = nullptr;
  };
  std::shared_ptr<NotificationGate> notifications_ =
      std::make_shared<NotificationGate>();

public:
  MacPcmOutput(PcmOutput &owner, const std::string &target,
               bool offline = false)
      : owner_(owner), target_(target), offline_(offline) {}
  ~MacPcmOutput() override {
    if (engine_)
      std::terminate();
  }
  void start() override {
    @autoreleasepool {
      engine_ = [[AVAudioEngine alloc] init];
      auto render = render_;
      render->owner = &owner_;
      auto *format =
          [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000
                                                         channels:2];
      source_ = [[AVAudioSourceNode alloc]
          initWithFormat:format
             renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *,
                                   AVAudioFrameCount frames,
                                   AudioBufferList *output) {
               render->callbacks.fetch_add(1, std::memory_order_seq_cst);
               struct Exit {
                 RenderGate &gate;
                 ~Exit() {
                   gate.callbacks.fetch_sub(1, std::memory_order_seq_cst);
                 }
               } exit{*render};
               auto *owner = render->owner.load(std::memory_order_seq_cst);
               if (!owner) {
                 for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
                   if (output->mBuffers[i].mData)
                     std::memset(output->mBuffers[i].mData, 0,
                                 output->mBuffers[i].mDataByteSize);
                 *silence = YES;
                 return noErr;
               }
               if (output->mNumberBuffers != 2 ||
                   output->mBuffers[0].mNumberChannels != 1 ||
                   output->mBuffers[1].mNumberChannels != 1 ||
                   output->mBuffers[0].mDataByteSize < frames * sizeof(float) ||
                   output->mBuffers[1].mDataByteSize < frames * sizeof(float) ||
                   !output->mBuffers[0].mData || !output->mBuffers[1].mData) {
                 for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
                   if (output->mBuffers[i].mData)
                     std::memset(output->mBuffers[i].mData, 0,
                                 output->mBuffers[i].mDataByteSize);
                 owner->fail(PcmOutput::Error::format);
                 return kAudio_ParamError;
               }
               owner->render(static_cast<float *>(output->mBuffers[0].mData),
                             static_cast<float *>(output->mBuffers[1].mData),
                             frames);
               *silence =
                   NO; // Queue may contain intentional silence, still PCM.
               return noErr;
             }];
      [engine_ attachNode:source_];
      [engine_ connect:source_ to:engine_.mainMixerNode format:format];
      if (!target_.empty() && target_ != "default" && target_ != "auto") {
        auto device = device_for_uid(target_);
        if (AudioUnitSetProperty(engine_.outputNode.audioUnit,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &device,
                                 sizeof(device)) != noErr)
          throw std::runtime_error("output_device_unavailable");
      }
      auto gate = notifications_;
      gate->owner = &owner_;
      observer_ = [[NSNotificationCenter defaultCenter]
          addObserverForName:AVAudioEngineConfigurationChangeNotification
                      object:engine_
                       queue:nil
                  usingBlock:^(NSNotification *) {
                    std::lock_guard lock(gate->mutex);
                    if (gate->owner)
                      gate->owner->fail(PcmOutput::Error::device_lost);
                  }];
      if (offline_) {
        NSError *error = nil;
        if (![engine_ enableManualRenderingMode:
                          AVAudioEngineManualRenderingModeOffline
                                         format:format
                              maximumFrameCount:4800
                                          error:&error])
          throw std::runtime_error("output_offline_configuration_failed");
      }
      [engine_ prepare];
      // Physical engine start is deferred until explicit prefill + resume.
    }
  }
#if FORESIGHT_ENABLE_TEST_HOOKS
  bool render_offline(float expected_left, float expected_right) {
    @autoreleasepool {
      auto *buffer = [[AVAudioPCMBuffer alloc]
          initWithPCMFormat:engine_.manualRenderingFormat
              frameCapacity:4800];
      NSError *error = nil;
      const auto status = [engine_ renderOffline:4800
                                        toBuffer:buffer
                                           error:&error];
      if (status != AVAudioEngineManualRenderingStatusSuccess ||
          buffer.frameLength != 4800 || !buffer.floatChannelData)
        return false;
      for (unsigned i = 0; i < 4800; ++i)
        if (buffer.floatChannelData[0][i] != expected_left ||
            buffer.floatChannelData[1][i] != expected_right)
          return false;
      return true;
    }
  }
#endif
  void resume() override {
    @autoreleasepool {
      NSError *error = nil;
      if (![engine_ startAndReturnError:&error]) {
        owner_.fail(PcmOutput::Error::unavailable);
        throw std::runtime_error("output_start_failed");
      }
    }
  }
  void pause() override {
    @autoreleasepool {
      [engine_ pause];
    }
  }
  void stop() override {
    @autoreleasepool {
      {
        std::lock_guard lock(notifications_->mutex);
        notifications_->owner = nullptr;
      }
      if (observer_) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer_];
        observer_ = nil;
      }
      render_->owner.store(nullptr, std::memory_order_seq_cst);
      [engine_ stop];
      while (render_->callbacks.load(std::memory_order_seq_cst))
        std::this_thread::sleep_for(std::chrono::microseconds(100));
      if (source_) {
        [engine_ disconnectNodeOutput:source_];
        [engine_ detachNode:source_];
      }
      source_ = nil;
      engine_ = nil;
    }
  }
};
#if FORESIGHT_ENABLE_TEST_HOOKS
thread_local MacPcmOutput *offline_instance = nullptr;
std::unique_ptr<PcmOutputBackend> offline_backend(PcmOutput &owner,
                                                  const std::string &target) {
  auto value = std::make_unique<MacPcmOutput>(owner, target, true);
  offline_instance = value.get();
  return value;
}
#endif
} // namespace
#if FORESIGHT_ENABLE_TEST_HOOKS
// Real AVAudioSourceNode/manual-engine render path; opens no physical device.
bool pcm_output_macos_offline_self_test() {
  PcmOutput output(1, "", offline_backend);
  bool success = false;
  try {
    std::array<int16_t, 9600> pcm{};
    for (unsigned i = 0; i < 4800; ++i) {
      pcm[i * 2] = 6000;
      pcm[i * 2 + 1] = -3000;
    }
    if (!output.start() || output.push(1, pcm.data(), 4800) != 4800 ||
        !output.resume(1) ||
        !offline_instance->render_offline(6000.0f / 32768, -3000.0f / 32768) ||
        output.snapshot().rendered_frames != 4800 ||
        !offline_instance->render_offline(0, 0) ||
        output.snapshot().rendered_frames != 4800)
      throw std::runtime_error("offline_PCM_render_mismatch");
    if (!output.request_flush(2) || !output.pause_flush(2) ||
        output.push(1, pcm.data(), 1) != -2)
      throw std::runtime_error("offline_flush_mismatch");
    pcm.fill(9000);
    if (output.push(2, pcm.data(), 4800) != 4800 || !output.resume(2) ||
        !offline_instance->render_offline(9000.0f / 32768, 9000.0f / 32768) ||
        output.snapshot().rendered_frames != 4800)
      throw std::runtime_error("offline_seek_mismatch");
    success = true;
  } catch (...) {
    success = false;
  }
  output.finish();
  offline_instance = nullptr;
  return success;
}
#endif
std::unique_ptr<PcmOutputBackend>
make_pcm_output_backend(PcmOutput &owner, const std::string &target) {
  return std::make_unique<MacPcmOutput>(owner, target);
}
} // namespace foresight
