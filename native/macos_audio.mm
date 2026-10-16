#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include "macos_audio.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <thread>
#include <memory>

namespace {
std::string json(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? std::string((const char *)data.bytes, data.length) : "null";
}
AudioObjectPropertyAddress property(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  return {selector, scope, kAudioObjectPropertyElementMain};
}
template<class T> bool get(AudioObjectID object, AudioObjectPropertySelector selector, T &value,
                           AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  auto address = property(selector, scope); UInt32 size = sizeof(value);
  return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value) == noErr;
}
NSString *text(AudioObjectID object, AudioObjectPropertySelector selector) {
  CFStringRef value = nullptr;
  if (!get(object, selector, value) || !value) return @"";
  return CFBridgingRelease(value);
}
std::vector<AudioDeviceID> devices() {
  auto address = property(kAudioHardwarePropertyDevices); UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size)) return {};
  std::vector<AudioDeviceID> result(size / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, result.data())) return {};
  return result;
}
bool hasChannels(AudioDeviceID device, bool playback) {
  auto address = property(kAudioDevicePropertyStreams, playback ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput);
  UInt32 size = 0;
  return !AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) && size > 0;
}
AudioDeviceID resolve(const std::string &target, bool playback) {
  AudioDeviceID device = kAudioObjectUnknown;
  if (target == "auto") get(kAudioObjectSystemObject, playback ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice, device);
  else for (auto id : devices()) if (target == [text(id, kAudioDevicePropertyDeviceUID) UTF8String] && hasChannels(id, playback)) return id;
  return device;
}
// Single producer / single consumer, two seconds at 192kHz. Never allocate,
// block, or emit JSON from a realtime callback. Overflow becomes a visible gap.
struct Ring {
  static constexpr size_t capacity = 384001;
  std::array<float, capacity> samples{};
  std::atomic<size_t> read{0}, write{0};
  std::atomic<uint64_t> dropped{0};
  void push(float value) {
    auto w = write.load(std::memory_order_relaxed), next = (w + 1) % capacity;
    if (next == read.load(std::memory_order_acquire)) { ++dropped; return; }
    samples[w] = value; write.store(next, std::memory_order_release);
  }
  bool pop(float &value) {
    auto r = read.load(std::memory_order_relaxed);
    if (r == write.load(std::memory_order_acquire)) return false;
    value = samples[r]; read.store((r + 1) % capacity, std::memory_order_release); return true;
  }
};
struct Session {
  Ring ring;
  std::atomic<bool> ready{false};
  OSStatus startStatus = noErr;
  AudioQueueRef queue = nullptr;
  AudioObjectID tap = kAudioObjectUnknown;
  AudioDeviceID aggregate = kAudioObjectUnknown;
  AudioDeviceIOProcID io = nullptr;
  AudioStreamBasicDescription format{};
  ~Session() {
    if (queue) { AudioQueueStop(queue, true); AudioQueueDispose(queue, true); }
    if (io) { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io); }
    if (aggregate) AudioHardwareDestroyAggregateDevice(aggregate);
    if (tap) AudioHardwareDestroyProcessTap(tap);
  }
};
void input(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer,
           const AudioTimeStamp *, UInt32, const AudioStreamPacketDescription *) {
  auto &s = *static_cast<Session *>(context);
  auto *p = static_cast<const int16_t *>(buffer->mAudioData);
  for (UInt32 i = 0; i < buffer->mAudioDataByteSize / 2; ++i) s.ring.push(p[i] / 32768.f);
  AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}
OSStatus output(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *data,
                const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *context) {
  auto &s = *static_cast<Session *>(context);
  if (!data || !data->mNumberBuffers) return noErr;
  UInt32 frames = data->mBuffers[0].mDataByteSize / s.format.mBytesPerFrame;
  for (UInt32 frame = 0; frame < frames; ++frame) {
    double sum = 0; unsigned channels = 0;
    for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
      auto &buffer = data->mBuffers[b];
      if (!buffer.mData) continue;
      for (UInt32 c = 0; c < buffer.mNumberChannels; ++c) {
        size_t offset = frame * buffer.mNumberChannels + c;
        if ((offset + 1) * (s.format.mBitsPerChannel / 8) > buffer.mDataByteSize) continue;
        if (s.format.mFormatFlags & kAudioFormatFlagIsFloat) {
          sum += s.format.mBitsPerChannel == 64 ? static_cast<const double *>(buffer.mData)[offset] : static_cast<const float *>(buffer.mData)[offset];
        } else if (s.format.mBitsPerChannel == 16) sum += static_cast<const int16_t *>(buffer.mData)[offset] / 32768.;
        else sum += static_cast<const int32_t *>(buffer.mData)[offset] / 2147483648.;
        ++channels;
      }
    }
    s.ring.push(channels ? float(sum / channels) : 0.f);
  }
  return noErr;
}
OSStatus start(Session &s, AudioDeviceID device, bool playback, int rate) {
  if (!playback) {
    s.format = {double(rate), kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 2, 1, 2, 1, 16, 0};
    OSStatus status = AudioQueueNewInput(&s.format, input, &s, nullptr, nullptr, 0, &s.queue);
    if (status) return status;
    CFStringRef uid = (__bridge CFStringRef)text(device, kAudioDevicePropertyDeviceUID);
    status = AudioQueueSetProperty(s.queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
    if (status) return status;
    for (int i = 0; i < 3; ++i) {
      AudioQueueBufferRef buffer = nullptr;
      status = AudioQueueAllocateBuffer(s.queue, rate * 2 * 40 / 1000, &buffer);
      if (status) return status;
      status = AudioQueueEnqueueBuffer(s.queue, buffer, 0, nullptr);
      if (status) return status;
    }
    return AudioQueueStart(s.queue, nullptr);
  }
  CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:@[] andDeviceUID:text(device, kAudioDevicePropertyDeviceUID) withStream:0];
  description.name = @"Open Foresight system audio";
  description.privateTap = YES; description.muteBehavior = CATapUnmuted;
  OSStatus status = AudioHardwareCreateProcessTap(description, &s.tap);
  if (status) return status;
  if (!get(s.tap, kAudioTapPropertyFormat, s.format)) return kAudioHardwareUnsupportedOperationError;
  if (s.format.mFormatID != kAudioFormatLinearPCM || !s.format.mBytesPerFrame ||
      (s.format.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
      !((s.format.mFormatFlags & kAudioFormatFlagIsFloat) ? (s.format.mBitsPerChannel == 32 || s.format.mBitsPerChannel == 64) :
        ((s.format.mFormatFlags & kAudioFormatFlagIsSignedInteger) && (s.format.mBitsPerChannel == 16 || s.format.mBitsPerChannel == 32)))) return kAudioHardwareUnsupportedOperationError;
  NSDictionary *config = @{@kAudioAggregateDeviceNameKey: @"Open Foresight private capture", @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
    @kAudioAggregateDeviceIsPrivateKey: @YES, @kAudioAggregateDeviceTapAutoStartKey: @NO,
    @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: description.UUID.UUIDString, @kAudioSubTapDriftCompensationKey: @YES}]};
  status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &s.aggregate);
  if (status) return status;
  status = AudioDeviceCreateIOProcID(s.aggregate, output, &s, &s.io);
  return status ? status : AudioDeviceStart(s.aggregate, s.io);
}
std::string micStatus() {
  switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
    case AVAuthorizationStatusAuthorized: return "authorized";
    case AVAuthorizationStatusDenied: return "denied";
    case AVAuthorizationStatusRestricted: return "restricted";
    default: return "not_determined";
  }
}
}
std::string fs_macos_devices() { @autoreleasepool {
  NSMutableArray *items = [NSMutableArray array];
  for (auto id : devices()) for (bool playback : {false, true}) if (hasChannels(id, playback))
    [items addObject:@{@"id":text(id, kAudioDevicePropertyDeviceUID), @"label":text(id, kAudioObjectPropertyName), @"playback":@(playback)}];
  return json(items);
} }
std::string fs_macos_capabilities() { @autoreleasepool {
  return json(@{@"microphone":[NSString stringWithUTF8String:micStatus().c_str()], @"system_audio":@"permission_checked_on_capture", @"backend":@"core_audio_tap", @"minimum_macos":@"15.0",
    @"microphone_purpose_present":@([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"] != nil),
    @"system_audio_purpose_present":@([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSAudioCaptureUsageDescription"] != nil)});
} }
bool fs_macos_request_microphone() { @autoreleasepool {
  if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"]) return false;
  dispatch_semaphore_t done = dispatch_semaphore_create(0); __block bool granted = false;
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL value) { granted = value; dispatch_semaphore_signal(done); }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); return granted;
} }
void fs_macos_capture(const std::string &target, bool playback, int rate, std::atomic<bool> &cancel,
    const std::function<void(const std::vector<unsigned char>&)> &pcm,
    const std::function<void(const std::string&)> &emit) { @autoreleasepool {
  auto event = [&](NSString *type, NSString *state, NSString *message, NSString *code) {
    emit(json(@{@"type":type, @"channel":@"foresight.linux/audio_state_v1", @"state":state, @"message":message, @"code":code}));
  };
  if (!playback && micStatus() != "authorized") {
    event(@"state", @"failed", @"Enable microphone access in System Settings > Privacy & Security > Microphone. If access has not been requested, request microphone access through the application service setup operation.", @"microphone_permission_required"); return;
  }
  if (![[NSBundle mainBundle] objectForInfoDictionaryKey:playback ? @"NSAudioCaptureUsageDescription" : @"NSMicrophoneUsageDescription"]) {
    event(@"state", @"failed", @"The responsible service executable is missing its audio purpose string. Launch the installed Open Foresight service bundle.", @"capture_bundle_misconfigured"); return;
  }
  int attempt = 0;
  while (!cancel) {
    event(@"state", @"connecting", @"Connecting audio device", @"");
    AudioDeviceID device = resolve(target, playback);
    if (!device) {
      emit(json(@{@"type":@"gap", @"reason":@"selected_device_unavailable", @"discarded_bytes":@0}));
      if (++attempt >= 5) { event(@"state", @"failed", @"Selected audio device is unavailable. Reconnect it or select another device.", @"device_unavailable"); return; }
      for (int i = 0; i < attempt * 10 && !cancel; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(100));
      continue;
    }
    auto ownedSession = std::make_shared<Session>();
    // Core Audio can wait on a system permission dialog. Keep cancellation and
    // service shutdown responsive; late completion owns and destroys its session.
    std::thread([ownedSession, device, playback, rate] { @autoreleasepool {
      ownedSession->startStatus = start(*ownedSession, device, playback, rate);
      ownedSession->ready.store(true, std::memory_order_release);
    } }).detach();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!ownedSession->ready.load(std::memory_order_acquire) && !cancel && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (cancel) return;
    if (!ownedSession->ready.load(std::memory_order_acquire)) {
      event(@"state", @"failed", @"Core Audio is waiting for access. Answer the system permission dialog or enable Screen & System Audio Recording in System Settings, then restart recording.", @"capture_permission_pending"); return;
    }
    auto &session = *ownedSession;
    OSStatus status = session.startStatus;
    if (status) {
      event(@"state", @"failed", [NSString stringWithFormat:@"Core Audio capture failed (%d). Check the selected device and Privacy & Security > %@; restart recording after granting access.", int(status), playback ? @"Screen & System Audio Recording" : @"Microphone"], @"core_audio_start_failed"); return;
    }
    event(@"state", @"capturing", @"Capturing audio", @"");
    std::vector<unsigned char> frame; frame.reserve(rate * 2 * 40 / 1000);
    // Continuous linear resampling; keep fractional position across callback blocks.
    double phase = 0, position = 0; float previous = 0; bool havePrevious = false;
    double initialDeviceRate = 0; get(device, kAudioDevicePropertyNominalSampleRate, initialDeviceRate);
    uint64_t dropped = 0; auto check = std::chrono::steady_clock::now(); bool reconnect = false;
    while (true) {
      if (cancel) {
        if (session.queue) AudioQueueStop(session.queue, true);
        if (session.io) AudioDeviceStop(session.aggregate, session.io);
      }
      float value;
      while (session.ring.pop(value)) {
        attempt = 0;
        if (!havePrevious) { previous = value; havePrevious = true; continue; }
        while (phase <= position + 1) {
          if (!std::isfinite(value)) value = 0;
          double sample = previous + (value - previous) * (phase - position);
          int16_t out = int16_t(std::lround(std::clamp(sample, -1., 1.) * 32767.));
          frame.push_back(out & 255); frame.push_back((uint16_t(out) >> 8) & 255);
          phase += session.format.mSampleRate / rate;
          if (frame.size() >= size_t(rate * 2 * 40 / 1000)) { pcm(frame); frame.clear(); }
        }
        previous = value; position += 1;
      }
      if (cancel) break;
      auto lost = session.ring.dropped.load();
      if (lost != dropped) { emit(json(@{@"type":@"gap", @"reason":@"capture_buffer_overflow", @"discarded_samples":@(lost - dropped)})); dropped = lost; }
      if (std::chrono::steady_clock::now() - check > std::chrono::milliseconds(250)) {
        if (!playback && micStatus() != "authorized") {
          event(@"state", @"failed", @"Microphone access was revoked. Enable it in System Settings and restart recording.", @"microphone_permission_revoked"); break;
        }
        UInt32 running = 1, runningSize = sizeof(running);
        if (session.queue) AudioQueueGetProperty(session.queue, kAudioQueueProperty_IsRunning, &running, &runningSize);
        else get(session.aggregate, kAudioDevicePropertyDeviceIsRunning, running);
        double deviceRate = initialDeviceRate; get(device, kAudioDevicePropertyNominalSampleRate, deviceRate);
        UInt32 alive = 0;
        if (!running || deviceRate != initialDeviceRate || resolve(target, playback) != device || !get(device, kAudioDevicePropertyDeviceIsAlive, alive) || !alive) { reconnect = true; break; }
        check = std::chrono::steady_clock::now();
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (!frame.empty()) pcm(frame); // Drain buffered final audio before returning.
    if (!reconnect || cancel) break;
    emit(json(@{@"type":@"gap", @"reason":@"audio_device_changed", @"discarded_bytes":@0}));
    ownedSession.reset();
    if (++attempt >= 5) { event(@"state", @"failed", @"Audio device retries exhausted. Select a device and restart recording.", @"device_unavailable"); break; }
    for (int i = 0; i < attempt * 10 && !cancel; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
} }
