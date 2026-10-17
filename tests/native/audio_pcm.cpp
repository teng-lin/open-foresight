// Deterministic checks of the exported PCM ABI. No capture devices are opened.
#include "foresight_native.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <vector>
#define REQUIRE(value) do { if (!(value)) throw std::runtime_error(#value); } while (false)

void resamplingRates() {
  // A linear ramp has an independent analytic interpolation result, including
  // the fractional 44.1 kHz -> 16 kHz positions.
  for (int rate : {44100, 48000}) {
    std::vector<int16_t> input(rate / 10);
    for (size_t i = 0; i < input.size(); ++i) input[i] = int16_t(3 * int(i) - 8000);
    std::vector<int16_t> output(1602, 12345);
    REQUIRE(fs_resample_pcm(input.data(), input.size(), rate, output.data(), 1600, 16000) == 1600);
    for (size_t i = 0; i < 1600; ++i) {
      const auto expected = std::lround(3.0 * double(i) * rate / 16000 - 8000);
      REQUIRE(std::abs(int(output[i]) - expected) <= 1);
    }
    REQUIRE(output[1600] == 12345 && output[1601] == 12345);
    // Output capacity bounds writes, even if the input contains more audio.
    output.assign(output.size(), 12345);
    REQUIRE(fs_resample_pcm(input.data(), input.size(), rate, output.data(), 7, 16000) == 7);
    REQUIRE(std::all_of(output.begin() + 7, output.end(), [](int16_t v) { return v == 12345; }));
  }
}

void interpolationBoundaries() {
  const std::array<int16_t, 3> input{0, 1000, 2000};
  std::array<int16_t, 6> output{};
  REQUIRE(fs_resample_pcm(input.data(), input.size(), 16000, output.data(), output.size(), 32000) == 6);
  REQUIRE((output == std::array<int16_t, 6>{0, 500, 1000, 1500, 2000, 2000}));
  const std::array<int16_t, 5> extremes{-32768, -1, 0, 1, 32767};
  std::array<int16_t, 5> copied{};
  REQUIRE(fs_resample_pcm(extremes.data(), extremes.size(), 16000, copied.data(), copied.size(), 16000) == 5);
  REQUIRE(copied == extremes);
  const int16_t single = -1234;
  output.fill(12345);
  REQUIRE(fs_resample_pcm(&single, 1, 8000, output.data(), output.size(), 16000) == 2);
  REQUIRE(output[0] == single && output[1] == single && output[2] == 12345);
  output.fill(12345);
  REQUIRE(fs_resample_pcm(&single, 1, 48000, output.data(), output.size(), 16000) == 0);
  REQUIRE(output[0] == 12345);
}

void invalidInputs() {
  const int16_t input = 100;
  int16_t output = 12345;
  REQUIRE(fs_resample_pcm(nullptr, 1, 16000, &output, 1, 16000) == 0);
  REQUIRE(fs_resample_pcm(&input, 1, 16000, nullptr, 1, 16000) == 0);
  REQUIRE(fs_resample_pcm(&input, 0, 16000, &output, 1, 16000) == 0);
  REQUIRE(fs_resample_pcm(&input, 1, 16000, &output, 0, 16000) == 0);
  for (int invalid : {0, -1}) {
    REQUIRE(fs_resample_pcm(&input, 1, invalid, &output, 1, 16000) == 0);
    REQUIRE(fs_resample_pcm(&input, 1, 16000, &output, 1, invalid) == 0);
  }
  REQUIRE(output == 12345);
}

void energyBoundaries() {
  REQUIRE(fs_pcm_rms(nullptr, 0) == 0);
  REQUIRE(fs_pcm_rms(nullptr, 10) == 0);
  const std::array<int16_t, 4> silence{};
  REQUIRE(fs_pcm_rms(silence.data(), silence.size()) == 0);
  const std::array<int16_t, 4> signal{-500, 500, -500, 500};
  REQUIRE(fs_pcm_rms(signal.data(), 0) == 0);
  REQUIRE(std::abs(fs_pcm_rms(signal.data(), signal.size()) - 500.0 / 32767) < 1e-12);
  const int16_t maximum = 32767, minimum = -32768;
  REQUIRE(fs_pcm_rms(&maximum, 1) == 1);
  REQUIRE(std::abs(fs_pcm_rms(&minimum, 1) - 32768.0 / 32767) < 1e-12);
  // A known waveform must retain its energy after 48 kHz -> 16 kHz conversion.
  std::vector<int16_t> input(4800), output(1600);
  const double pi = std::acos(-1.0);
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = int16_t(std::lround(16383.5 * std::sin(2 * pi * 1000 * i / 48000)));
  REQUIRE(fs_resample_pcm(input.data(), input.size(), 48000, output.data(), output.size(), 16000) == output.size());
  REQUIRE(std::abs(fs_pcm_rms(output.data(), output.size()) - .5 / std::sqrt(2.0)) < 1e-4);
}

int main() {
  try {
    resamplingRates();
    interpolationBoundaries();
    invalidInputs();
    energyBoundaries();
    std::cout << "PCM resampling rates, capacity, invalid-input and energy contracts passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
