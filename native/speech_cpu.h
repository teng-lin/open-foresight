#pragma once

#include <optional>
#include <string>

#if defined(__x86_64__)
#include <cpuid.h>
#endif

// Empty means the Linux x86-64 Whisper build may start. Otherwise the string
// is reported on the speech-runtime error channel instead of executing it.
inline std::optional<std::string>
speech_cpu_blocker(bool has_avx2, bool has_fma, bool has_f16c) {
  if (has_avx2 && has_fma && has_f16c)
    return std::nullopt;
  std::string missing;
  auto append = [&](bool present, const char *name) {
    if (present)
      return;
    if (!missing.empty())
      missing += ", ";
    missing += name;
  };
  append(has_avx2, "AVX2");
  append(has_fma, "FMA");
  append(has_f16c, "F16C");
  return "Speech runtime requires AVX2, FMA, and F16C; this CPU is missing " +
         missing + ". Transcription was not started.";
}

inline void speech_cpu_features(bool &has_avx2, bool &has_fma, bool &has_f16c) {
#if defined(__x86_64__)
  has_avx2 = has_fma = has_f16c = false;
  unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
  if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx))
    return;
  const bool os_avx = (ecx & (1u << 27)) != 0 && (ecx & (1u << 28)) != 0;
  bool ymm = false;
  if (os_avx) {
    unsigned int a = 0, d = 0;
    __asm__ volatile("xgetbv" : "=a"(a), "=d"(d) : "c"(0));
    ymm = (a & 0x6) == 0x6;
  }
  if (!ymm)
    return;
  has_fma = (ecx & (1u << 12)) != 0;
  has_f16c = (ecx & (1u << 29)) != 0;
  if (__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx))
    has_avx2 = (ebx & (1u << 5)) != 0;
#else
  has_avx2 = has_fma = has_f16c = true;
#endif
}

// The packaged Linux x86-64 Whisper binary is the one that SIGILLs without
// AVX2, FMA, and F16C. Other builds do not use this probe.
inline std::optional<std::string> linux_speech_cpu_block() {
#if defined(__linux__) && defined(__x86_64__)
  bool has_avx2 = false, has_fma = false, has_f16c = false;
  speech_cpu_features(has_avx2, has_fma, has_f16c);
  return speech_cpu_blocker(has_avx2, has_fma, has_f16c);
#else
  return std::nullopt;
#endif
}
