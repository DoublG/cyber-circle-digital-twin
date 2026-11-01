#pragma once
#include <cstdint>
#include <string>
#include "WString.h"

class IPAddress {
  public:
    IPAddress(uint8_t a = 0, uint8_t b = 0, uint8_t c = 0, uint8_t d = 0) : b_{a, b, c, d} {}
    uint8_t operator[](int i) const { return b_[i]; }
    uint8_t &operator[](int i) { return b_[i]; }
    String toString() const {
        return String(std::to_string(b_[0]) + "." + std::to_string(b_[1]) + "." + std::to_string(b_[2]) + "." + std::to_string(b_[3]));
    }

  private:
    uint8_t b_[4];
};
