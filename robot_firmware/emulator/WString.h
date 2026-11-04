// Arduino's String, as far as the firmware uses it (the tile emulator).
#pragma once
#include <string>

class String {
  public:
    String() {}
    String(const char *s) : s_(s ? s : "") {}
    String(const std::string &s) : s_(s) {}
    String(int v) : s_(std::to_string(v)) {}
    const char *c_str() const { return s_.c_str(); }
    unsigned length() const { return s_.size(); }
    bool isEmpty() const { return s_.empty(); }
    void replace(const String &from, const String &to) {
        for (size_t p = 0; !from.s_.empty() && (p = s_.find(from.s_, p)) != std::string::npos; p += to.s_.size())
            s_.replace(p, from.s_.size(), to.s_);
    }
    String operator+(const String &o) const { return String(s_ + o.s_); }
    String operator+(const char *o) const { return String(s_ + o); }
    String operator+(int v) const { return String(s_ + std::to_string(v)); }
    friend String operator+(const char *a, const String &b) { return String(std::string(a) + b.s_); }
    String &operator+=(const String &o) { s_ += o.s_; return *this; }
    bool concat(const char *o) { s_ += o ? o : ""; return true; }     // (ArduinoJson writes into a String)
    bool operator==(const String &o) const { return s_ == o.s_; }
    bool operator==(const char *o) const { return s_ == o; }
    bool operator!=(const String &o) const { return s_ != o.s_; }
    bool operator!=(const char *o) const { return s_ != o; }

  private:
    std::string s_;
};
