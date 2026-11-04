#pragma once

#include <stdint.h>
#include <string.h>

#include <algorithm>
#include <string_view>

namespace exynos990::metadata {

constexpr std::string_view kStandardName =
        "android.hardware.graphics.common.StandardMetadataType";

class Writer {
  public:
    Writer(void* output, size_t capacity)
        : output_(static_cast<uint8_t*>(output)), capacity_(capacity) {}

    template <typename T>
    void scalar(T value) {
        write(&value, sizeof(value));
    }

    void string(std::string_view value) {
        scalar<int64_t>(value.size());
        write(value.data(), value.size());
    }

    template <typename T>
    int32_t standard(int64_t type, T value) {
        string(kStandardName);
        scalar<int64_t>(type);
        scalar<T>(value);
        return size();
    }

    int32_t standardString(int64_t type, std::string_view value) {
        string(kStandardName);
        scalar<int64_t>(type);
        string(value);
        return size();
    }

    int32_t standardExtendable(int64_t type, std::string_view name, int64_t value) {
        string(kStandardName);
        scalar<int64_t>(type);
        string(name);
        scalar<int64_t>(value);
        return size();
    }

    int32_t standardBytes(int64_t type, const void* value, size_t valueSize) {
        string(kStandardName);
        scalar<int64_t>(type);
        write(value, valueSize);
        return size();
    }

    void header(int64_t type) {
        string(kStandardName);
        scalar<int64_t>(type);
    }

    int32_t size() const { return overflow_ ? -3 : static_cast<int32_t>(wanted_); }

  private:
    void write(const void* source, size_t length) {
        if (wanted_ > INT32_MAX - length) {
            overflow_ = true;
            return;
        }
        if (output_ && wanted_ + length <= capacity_) {
            memcpy(output_ + wanted_, source, length);
        }
        wanted_ += length;
    }

    uint8_t* output_;
    size_t capacity_;
    size_t wanted_ = 0;
    bool overflow_ = false;
};

}  // namespace exynos990::metadata

