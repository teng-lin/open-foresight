#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include "macos_audio.h"
#include "voice_processing.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <thread>
#include <memory>
#include <mutex>

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
  std::atomic<bool> changed{false};
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
  std::shared_ptr<Ring> ring = std::make_shared<Ring>();
  bool discardAudio = false;
  std::atomic<bool> ready{false};
  OSStatus startStatus = noErr;
  AudioObjectID tap = kAudioObjectUnknown;
  AudioDeviceID aggregate = kAudioObjectUnknown;
  AudioDeviceIOProcID io = nullptr;
  AudioStreamBasicDescription format{};
  AVAudioEngine *engine = nil;
  id engineObserver = nil;
  bool tapInstalled = false;
  int echoFallback = 0;
  void resetEngine() {
    if (engineObserver) [[NSNotificationCenter defaultCenter] removeObserver:engineObserver];
    engineObserver = nil;
    if (engine) {
      [engine stop];
      if (tapInstalled) [engine.inputNode removeTapOnBus:0];
      [engine reset];
    }
    tapInstalled = false;
    engine = nil;
  }
  ~Session() {
    resetEngine();
    if (io) { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io); }
    if (aggregate) AudioHardwareDestroyAggregateDevice(aggregate);
    if (tap) AudioHardwareDestroyProcessTap(tap);
  }
};
bool supportedPcm(const AudioStreamBasicDescription &format) {
  return format.mFormatID == kAudioFormatLinearPCM && format.mBytesPerFrame &&
      !(format.mFormatFlags & kAudioFormatFlagIsBigEndian) &&
      ((format.mFormatFlags & kAudioFormatFlagIsFloat) ?
          (format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64) :
          ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
              (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32)));
}
void pushAudio(Ring &ring, const AudioStreamBasicDescription &format, const AudioBufferList *data, bool firstChannel = false) {
  if (!data || !data->mNumberBuffers) return;
  if (!supportedPcm(format)) { ring.changed = true; return; }
  UInt32 frames = data->mBuffers[0].mDataByteSize / format.mBytesPerFrame;
  for (UInt32 frame = 0; frame < frames; ++frame) {
    double sum = 0; unsigned channels = 0;
    for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
      if (firstChannel && b > 0) break;
      auto &buffer = data->mBuffers[b];
      if (!buffer.mData) continue;
      for (UInt32 c = 0; c < buffer.mNumberChannels; ++c) {
        if (firstChannel && c > 0) break;
        size_t offset = frame * buffer.mNumberChannels + c;
        if ((offset + 1) * (format.mBitsPerChannel / 8) > buffer.mDataByteSize) continue;
        if (format.mFormatFlags & kAudioFormatFlagIsFloat) {
          sum += format.mBitsPerChannel == 64 ? static_cast<const double *>(buffer.mData)[offset] : static_cast<const float *>(buffer.mData)[offset];
        } else if (format.mBitsPerChannel == 16) sum += static_cast<const int16_t *>(buffer.mData)[offset] / 32768.;
        else sum += static_cast<const int32_t *>(buffer.mData)[offset] / 2147483648.;
        ++channels;
      }
    }
    ring.push(channels ? float(sum / channels) : 0.f);
  }
}
OSStatus output(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *data,
                const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *context) {
  auto &s = *static_cast<Session *>(context);
  // Permission setup must not inspect, buffer, or publish private PCM.
  if (s.discardAudio) return noErr;
  pushAudio(*s.ring, s.format, data);
  return noErr;
}
OSStatus startEngine(Session &s, AudioDeviceID device, bool processed) { @try {
  s.engine = [[AVAudioEngine alloc] init];
  AVAudioInputNode *node = s.engine.inputNode;
  NSError *error = nil;
  if (processed) {
    (void)s.engine.outputNode;
    if (![node setVoiceProcessingEnabled:YES error:&error])
      return error ? OSStatus(error.code) : kAudioHardwareUnsupportedOperationError;
    node.voiceProcessingAGCEnabled = NO;
    node.voiceProcessingInputMuted = NO;
    node.voiceProcessingOtherAudioDuckingConfiguration = {YES, AVAudioVoiceProcessingOtherAudioDuckingLevelMin};
  }
  AudioUnit unit = node.audioUnit;
  if (!unit) return kAudioHardwareBadDeviceError;
  OSStatus status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global, 0, &device, sizeof(device));
  if (status) return status;
  auto valid = [](AVAudioFormat *f) { return f && std::isfinite(f.sampleRate) && f.sampleRate > 0 && f.channelCount > 0; };
  AVAudioFormat *format = [node outputFormatForBus:0];
  for (int attempt = 0; !valid(format) && attempt <= 5; ++attempt) {
    AVAudioFormat *inputFormat = [node inputFormatForBus:0];
    if (valid(inputFormat)) { format = inputFormat; break; }
    if (attempt == 5) break;
    [s.engine reset];
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    format = [node outputFormatForBus:0];
  }
  if (!valid(format)) return kAudioHardwareUnsupportedOperationError;
  s.format = *format.streamDescription;
  if (!supportedPcm(s.format)) return kAudioHardwareUnsupportedOperationError;
  auto ring = s.ring;
  const double sampleRate = format.sampleRate;
  [node installTapOnBus:0 bufferSize:1024 format:nil block:^(AVAudioPCMBuffer *buffer, AVAudioTime *) {
    // The callback owns only the ring. Late callbacks cannot touch a destroyed
    // capture session; conversion, JSON, and model work stay off this thread.
    const auto &actual = *buffer.format.streamDescription;
    if (actual.mSampleRate != sampleRate) { ring->changed = true; return; }
    // The original's converter maps the first source channel when reducing
    // microphone input to mono, rather than averaging phase-opposed channels.
    pushAudio(*ring, actual, buffer.audioBufferList, true);
  }];
  s.tapInstalled = true;
  [s.engine prepare];
  const int attempts = processed ? 3 : 1;
  for (int attempt = 0; attempt < attempts; ++attempt) {
    error = nil;
    if ([s.engine startAndReturnError:&error]) {
      s.engineObserver = [[NSNotificationCenter defaultCenter]
          addObserverForName:AVAudioEngineConfigurationChangeNotification object:s.engine queue:nil
          usingBlock:^(NSNotification *) { ring->changed = true; }];
      return noErr;
    }
    if (attempt + 1 < attempts) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return error ? OSStatus(error.code) : kAudioHardwareUnspecifiedError;
} @catch (NSException *) { return kAudioHardwareUnsupportedOperationError; } }
OSStatus start(Session &s, AudioDeviceID device, bool playback, int /*rate*/, bool echo = false) {
  if (!playback) {
    const auto result = startVoiceCapture(echo, [&] {
      s.resetEngine(); s.ring = std::make_shared<Ring>();
    }, [&](bool processed) { return startEngine(s, device, processed); });
    s.echoFallback = result.fallbackReason;
    return result.status;
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
struct SystemAudioRequest {
  std::atomic<bool> completed{false};
  OSStatus status = noErr; // Published by completed's release/acquire pair.
};
std::mutex systemRequestMutex;
std::shared_ptr<SystemAudioRequest> systemRequest;
NSString *const systemAudioSettings = @"x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture";
NSString *const systemAudioInstructions = @"In System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, enable Open Foresight (or the service shown by macOS), then retry. On some macOS versions the section is named System Audio Recording.";
NSDictionary *systemAudioState(const std::shared_ptr<SystemAudioRequest> &request) {
  NSString *state = @"unknown", *phase = @"not_requested", *code = @"system_audio_permission_unknown";
  NSString *message = @"Request system audio access explicitly. macOS does not expose a public Core Audio permission status check.";
  OSStatus status = noErr;
  if (request) {
    if (!request->completed.load(std::memory_order_acquire)) {
      state = @"pending"; phase = @"requesting"; code = @"system_audio_permission_pending";
      message = [@"Answer the macOS system audio permission dialog, if shown. " stringByAppendingString:systemAudioInstructions];
    } else {
      status = request->status;
      phase = status ? @"failed" : @"completed";
      if (status == kAudioDevicePermissionsError) {
        state = @"denied"; code = @"system_audio_device_permission_denied";
        message = [@"Core Audio denied access to the audio device. " stringByAppendingString:systemAudioInstructions];
      } else if (status == kAudioHardwareBadDeviceError) {
        state = @"unavailable"; code = @"device_unavailable";
        message = @"No system audio output device is available. Connect or select an output device, then retry.";
      } else if (status) {
        state = @"unavailable"; code = @"system_audio_request_failed";
        message = [NSString stringWithFormat:@"Core Audio could not start the system audio access request (%d). Check the output device. %@", int(status), systemAudioInstructions];
      } else {
        // A successful tap may deliver silence when permission is denied.
        // Neither success nor silence establishes authorization.
        code = @"system_audio_permission_unverified";
        message = [@"The system audio access request completed. macOS may have shown a permission prompt; permission cannot be verified through the public Core Audio API. " stringByAppendingString:systemAudioInstructions];
      }
    }
  }
  NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
  NSString *bundleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
  return @{@"system_audio":state, @"system_audio_request":phase,
           @"permission_verified":@NO, @"code":code, @"message":message,
           @"settings_url":systemAudioSettings, @"os_status":@(status),
           @"requesting_bundle_id":bundleID ? bundleID : @"",
           @"requesting_bundle_name":bundleName ? bundleName : @""};
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
  std::shared_ptr<SystemAudioRequest> request;
  { std::lock_guard lock(systemRequestMutex); request = systemRequest; }
  NSMutableDictionary *result = [systemAudioState(request) mutableCopy];
  [result addEntriesFromDictionary:@{@"microphone":[NSString stringWithUTF8String:micStatus().c_str()],
    @"echo_cancellation_supported":@YES, @"echo_cancellation_default":@NO,
    @"backend":@"core_audio_tap", @"minimum_macos":@"15.0",
    @"microphone_purpose_present":@([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"] != nil),
    @"system_audio_purpose_present":@([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSAudioCaptureUsageDescription"] != nil)}];
  return json(result);
} }
std::string fs_macos_request_system(int timeout_ms) { @autoreleasepool {
  if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSAudioCaptureUsageDescription"]) {
    return json(@{@"system_audio":@"unavailable", @"system_audio_request":@"failed",
      @"permission_verified":@NO, @"code":@"capture_bundle_misconfigured",
      @"message":@"The requesting process is missing NSAudioCaptureUsageDescription. Launch the installed Open Foresight service bundle.",
      @"settings_url":systemAudioSettings});
  }
  std::shared_ptr<SystemAudioRequest> request;
  {
    std::lock_guard lock(systemRequestMutex);
    request = systemRequest;
    if (!request || request->completed.load(std::memory_order_acquire)) {
      request = systemRequest = std::make_shared<SystemAudioRequest>();
      // Match recording's late-completion ownership: Core Audio can wait on
      // consent; returning on timeout never destroys a session still in use.
      // Keep a single in-flight request so repeated clicks cannot create taps.
      try {
        std::thread([request] { @autoreleasepool {
          OSStatus status = kAudioHardwareUnspecifiedError;
          try {
            AudioDeviceID device = resolve("auto", true);
            if (!device) status = kAudioHardwareBadDeviceError;
            else {
              auto session = std::make_unique<Session>();
              session->discardAudio = true;
              status = start(*session, device, true, 48000);
            }
          } catch (...) {
            // Never let thread/allocation failures terminate the service.
          } // Stop IO and destroy the private aggregate/tap before reporting.
          request->status = status;
          request->completed.store(true, std::memory_order_release);
        } }).detach();
      } catch (...) {
        request->status = kAudioHardwareUnspecifiedError;
        request->completed.store(true, std::memory_order_release);
      }
    }
  }
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(std::clamp(timeout_ms, 0, 30000));
  while (!request->completed.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  return json(systemAudioState(request));
} }
bool fs_macos_request_microphone() { @autoreleasepool {
  if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"]) return false;
  dispatch_semaphore_t done = dispatch_semaphore_create(0); __block bool granted = false;
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL value) { granted = value; dispatch_semaphore_signal(done); }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); return granted;
} }
void fs_macos_capture(const std::string &target, bool playback, int rate, std::atomic<bool> &cancel,
    const std::function<void(const std::vector<unsigned char>&)> &pcm,
    const std::function<void(const std::string&)> &emit,
    std::atomic<bool> *echoCancellation) { @autoreleasepool {
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
    const bool requested = !playback && echoCancellation && echoCancellation->load();
    std::thread([ownedSession, device, playback, rate, requested] { @autoreleasepool {
      ownedSession->startStatus = start(*ownedSession, device, playback, rate, requested);
      ownedSession->ready.store(true, std::memory_order_release);
    } }).detach();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!ownedSession->ready.load(std::memory_order_acquire) && !cancel && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (cancel) return;
    if (!ownedSession->ready.load(std::memory_order_acquire)) {
      event(@"state", @"failed", [@"Core Audio is waiting for access. Answer the system permission dialog. " stringByAppendingString:systemAudioInstructions], @"capture_permission_pending"); return;
    }
    auto &session = *ownedSession;
    OSStatus status = session.startStatus;
    if (status) {
      event(@"state", @"failed", [NSString stringWithFormat:@"Core Audio capture failed (%d). Check the selected device and Privacy & Security > %@; restart recording after granting access.", int(status), playback ? @"Screen & System Audio Recording > System Audio Recording Only" : @"Microphone"], @"core_audio_start_failed"); return;
    }
    event(@"state", @"capturing", @"Capturing audio", @"");
    bool appliedEcho = requested;
    auto echoState = [&](bool desired) {
      const bool active = session.engine && session.engine.inputNode.voiceProcessingEnabled &&
          !session.engine.inputNode.voiceProcessingBypassed;
      emit(json(@{@"type":@"echo_cancellation", @"supported":@YES,
          @"requested":@(desired), @"active":@(active),
          @"restart_required":@(desired && !session.engine.inputNode.voiceProcessingEnabled),
          @"fallback_status":@(session.echoFallback)}));
    };
    if (!playback) {
      if (session.echoFallback && echoCancellation) {
        echoCancellation->store(false); appliedEcho = false;
      }
      echoState(appliedEcho);
    }
    std::vector<unsigned char> frame; frame.reserve(rate * 2 * 40 / 1000);
    // Continuous linear resampling; keep fractional position across callback blocks.
    double phase = 0, position = 0; float previous = 0; bool havePrevious = false;
    double initialDeviceRate = 0; get(device, kAudioDevicePropertyNominalSampleRate, initialDeviceRate);
    uint64_t dropped = 0; auto check = std::chrono::steady_clock::now(); bool reconnect = false;
    while (true) {
      if (cancel) {
        if (session.engine) [session.engine stop];
        if (session.io) AudioDeviceStop(session.aggregate, session.io);
      }
      float value;
      while (session.ring->pop(value)) {
        attempt = 0;
        if (!std::isfinite(value)) value = 0;
        if (!havePrevious) { previous = value; havePrevious = true; continue; }
        while (phase <= position + 1) {
          double sample = previous + (value - previous) * (phase - position);
          int16_t out = int16_t(std::lround(std::clamp(sample, -1., 1.) * 32767.));
          frame.push_back(out & 255); frame.push_back((uint16_t(out) >> 8) & 255);
          phase += session.format.mSampleRate / rate;
          if (frame.size() >= size_t(rate * 2 * 40 / 1000)) { pcm(frame); frame.clear(); }
        }
        previous = value; position += 1;
      }
      if (cancel) break;
      if (!playback && echoCancellation && echoCancellation->load() != appliedEcho) {
        appliedEcho = echoCancellation->load();
        if (session.engine.inputNode.voiceProcessingEnabled)
          session.engine.inputNode.voiceProcessingBypassed = !appliedEcho;
        echoState(appliedEcho);
      }
      auto lost = session.ring->dropped.load();
      if (lost != dropped) { emit(json(@{@"type":@"gap", @"reason":@"capture_buffer_overflow", @"discarded_samples":@(lost - dropped)})); dropped = lost; }
      if (std::chrono::steady_clock::now() - check > std::chrono::milliseconds(250)) {
        if (!playback && micStatus() != "authorized") {
          event(@"state", @"failed", @"Microphone access was revoked. Enable it in System Settings and restart recording.", @"microphone_permission_revoked"); break;
        }
        UInt32 running = 1;
        if (session.engine) running = session.engine.running;
        else get(session.aggregate, kAudioDevicePropertyDeviceIsRunning, running);
        double deviceRate = initialDeviceRate; get(device, kAudioDevicePropertyNominalSampleRate, deviceRate);
        UInt32 alive = 0;
        if (!running || session.ring->changed || deviceRate != initialDeviceRate || resolve(target, playback) != device || !get(device, kAudioDevicePropertyDeviceIsAlive, alive) || !alive) { reconnect = true; break; }
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
