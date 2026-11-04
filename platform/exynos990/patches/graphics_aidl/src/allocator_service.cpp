// Copyright (c) 2026 At30c
// SPDX-License-Identifier: GPL-3.0-or-later
#include <aidl/android/hardware/common/NativeHandle.h>
#include <aidl/android/hardware/graphics/allocator/AllocationError.h>
#include <aidl/android/hardware/graphics/allocator/AllocationResult.h>
#include <aidl/android/hardware/graphics/allocator/BnAllocator.h>
#include <android/binder_ibinder.h>
#include <android/binder_status.h>
#include <hardware/gralloc1.h>
#include <unistd.h>

#include "exynos990/graphics_backend.h"
#include "exynos990/graphics_contract.h"

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

namespace {

extern "C" int __android_log_print(int priority, const char* tag, const char* format, ...);
extern "C" void ABinderProcess_setThreadPoolMaxThreadCount(uint32_t numThreads);
extern "C" void ABinderProcess_joinThreadPool(void);
extern "C" binder_status_t AServiceManager_addService(AIBinder* binder, const char* instance);
#define ALOGE(...) __android_log_print(6, "Exynos990AllocatorBridge", __VA_ARGS__)

namespace allocator = aidl::android::hardware::graphics::allocator;
using aidl::android::hardware::common::NativeHandle;
using allocator::AllocationError;
using allocator::AllocationResult;
using allocator::BufferDescriptorInfo;

ndk::ScopedAStatus allocationError(AllocationError error, const char* message) {
    ALOGE("%s", message);
    return ndk::ScopedAStatus::fromServiceSpecificErrorWithMessage(
            static_cast<int32_t>(error), message);
}

class LegacyAllocator final : public allocator::BnAllocator {
  public:
    LegacyAllocator() {
        backend_ = exynos990_gralloc_backend();
        if (!backend_ || !backend_->ready) {
            ALOGE("Unable to open stock Exynos 990 gralloc1 backend");
            return;
        }
        device_ = backend_->device;
        create_ = backend_->createDescriptor;
        destroy_ = backend_->destroyDescriptor;
        setDimensions_ = backend_->setDimensions;
        setFormat_ = backend_->setFormat;
        setLayers_ = backend_->setLayerCount;
        setProducerUsage_ = backend_->setProducerUsage;
        setConsumerUsage_ = backend_->setConsumerUsage;
        allocate_ = backend_->allocate;
        release_ = backend_->release;
        stride_ = backend_->getStride;
        ready_ = create_ && destroy_ && setDimensions_ && setFormat_ && setLayers_ &&
                 setProducerUsage_ && setConsumerUsage_ && allocate_ && release_ && stride_;
        if (!ready_) ALOGE("Stock gralloc1 is missing an allocator callback");
    }

    ndk::ScopedAStatus allocate(const std::vector<uint8_t>&, int32_t,
                                AllocationResult*) override {
        return allocationError(AllocationError::BAD_DESCRIPTOR,
                               "Mapper 4 descriptor blobs are not accepted by Mapper 5 bridge");
    }

    ndk::ScopedAStatus allocate2(const BufferDescriptorInfo& info, int32_t count,
                                 AllocationResult* result) override {
        if (!ready_ || !result || count <= 0 || count > 64) {
            return allocationError(AllocationError::BAD_DESCRIPTOR,
                                   "Invalid or unsupported buffer descriptor");
        }
        result->stride = 0;
        result->buffers.clear();

        gralloc1_buffer_descriptor_t descriptor = 0;
        int32_t error = configureDescriptor(info, &descriptor);
        if (error) {
            if (descriptor) destroy_(device_, descriptor);
            return allocationError(AllocationError::BAD_DESCRIPTOR,
                                   "Stock gralloc rejected the descriptor");
        }

        std::vector<buffer_handle_t> buffers(count, nullptr);
        std::vector<gralloc1_buffer_descriptor_t> descriptors(count, descriptor);
        error = allocate_(device_, count, descriptors.data(), buffers.data());
        destroy_(device_, descriptor);
        if (error) {
            return allocationError(error == GRALLOC1_ERROR_NO_RESOURCES
                                           ? AllocationError::NO_RESOURCES
                                           : AllocationError::UNSUPPORTED,
                                   "Stock gralloc allocation failed");
        }

        uint32_t stride = 0;
        error = stride_(device_, buffers.front(), &stride);
        if (error) {
            releaseAll(buffers);
            return allocationError(AllocationError::NO_RESOURCES,
                                   "Unable to read allocated buffer stride");
        }

        result->stride = static_cast<int32_t>(stride);
        result->buffers.clear();
        result->buffers.reserve(count);
        for (buffer_handle_t handle : buffers) {
            NativeHandle parcelable;
            parcelable.fds.reserve(handle->numFds);
            parcelable.ints.reserve(handle->numInts);
            bool dupFailed = false;
            for (int i = 0; i < handle->numFds; ++i) {
                int copied = dup(handle->data[i]);
                if (copied < 0) {
                    dupFailed = true;
                    break;
                }
                parcelable.fds.emplace_back(copied);
            }
            for (int i = 0; i < handle->numInts; ++i) {
                parcelable.ints.push_back(handle->data[handle->numFds + i]);
            }
            if (dupFailed) {
                releaseAll(buffers);
                result->buffers.clear();
                return allocationError(AllocationError::NO_RESOURCES,
                                       "Unable to duplicate native handle fds");
            }
            result->buffers.emplace_back(std::move(parcelable));
        }
        releaseAll(buffers);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus isSupported(const BufferDescriptorInfo& info, bool* supported) override {
        if (!supported) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        *supported = false;
        if (!ready_ || info.width <= 0 || info.height <= 0 || info.layerCount <= 0 ||
            info.reservedSize != 0 || !info.additionalOptions.empty() ||
            (static_cast<uint64_t>(info.usage) & exynos990::graphics::kAidlUnsupportedUsageMask)) {
            return ndk::ScopedAStatus::ok();
        }

        // Gralloc1 has no capability query for a complete descriptor. Probe
        // one buffer so the global AIDL allocator does not advertise formats
        // or usage combinations that the proprietary driver will reject.
        gralloc1_buffer_descriptor_t descriptor = 0;
        if (configureDescriptor(info, &descriptor) != GRALLOC1_ERROR_NONE) {
            if (descriptor) destroy_(device_, descriptor);
            return ndk::ScopedAStatus::ok();
        }
        buffer_handle_t buffer = nullptr;
        const int32_t error = allocate_(device_, 1, &descriptor, &buffer);
        destroy_(device_, descriptor);
        if (error == GRALLOC1_ERROR_NONE && buffer) {
            uint32_t stride = 0;
            *supported = stride_(device_, buffer, &stride) == GRALLOC1_ERROR_NONE;
            release_(device_, buffer);
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getIMapperLibrarySuffix(std::string* suffix) override {
        if (!suffix) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        *suffix = "exynos990_compat";
        return ndk::ScopedAStatus::ok();
    }

    bool ready() const { return ready_; }

  private:
    int32_t configureDescriptor(const BufferDescriptorInfo& info,
                                gralloc1_buffer_descriptor_t* descriptor) {
        if (!descriptor || info.width <= 0 || info.height <= 0 || info.layerCount <= 0 ||
            info.reservedSize != 0 || !info.additionalOptions.empty() ||
            (static_cast<uint64_t>(info.usage) & exynos990::graphics::kAidlUnsupportedUsageMask)) {
            return GRALLOC1_ERROR_BAD_DESCRIPTOR;
        }
        int32_t error = create_(device_, descriptor);
        if (!error) error = setDimensions_(device_, *descriptor, info.width, info.height);
        if (!error) error = setFormat_(device_, *descriptor, static_cast<int32_t>(info.format));
        if (!error) error = setLayers_(device_, *descriptor, info.layerCount);
        const uint64_t usage = static_cast<uint64_t>(info.usage);
        if (!error) error = setProducerUsage_(device_, *descriptor,
                                              exynos990::graphics::toProducerUsage(usage));
        if (!error) error = setConsumerUsage_(device_, *descriptor,
                                              exynos990::graphics::toConsumerUsage(usage));
        return error;
    }

    void releaseAll(const std::vector<buffer_handle_t>& buffers) {
        for (buffer_handle_t buffer : buffers) {
            if (buffer) release_(device_, buffer);
        }
    }

    gralloc1_device_t* device_ = nullptr;
    GRALLOC1_PFN_CREATE_DESCRIPTOR create_ = nullptr;
    GRALLOC1_PFN_DESTROY_DESCRIPTOR destroy_ = nullptr;
    GRALLOC1_PFN_SET_DIMENSIONS setDimensions_ = nullptr;
    GRALLOC1_PFN_SET_FORMAT setFormat_ = nullptr;
    GRALLOC1_PFN_SET_LAYER_COUNT setLayers_ = nullptr;
    GRALLOC1_PFN_SET_PRODUCER_USAGE setProducerUsage_ = nullptr;
    GRALLOC1_PFN_SET_CONSUMER_USAGE setConsumerUsage_ = nullptr;
    GRALLOC1_PFN_ALLOCATE allocate_ = nullptr;
    GRALLOC1_PFN_RELEASE release_ = nullptr;
    GRALLOC1_PFN_GET_STRIDE stride_ = nullptr;
    const exynos990_gralloc_backend_t* backend_ = nullptr;
    bool ready_ = false;
};

}  // namespace

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(4);
    auto service = ndk::SharedRefBase::make<LegacyAllocator>();
    if (!service->ready()) return 1;
    const std::string instance = std::string(allocator::IAllocator::descriptor) + "/default";
    binder_status_t status = AServiceManager_addService(service->asBinder().get(), instance.c_str());
    if (status != STATUS_OK) {
        ALOGE("Unable to register %s: %d", instance.c_str(), status);
        return 1;
    }
    ABinderProcess_joinThreadPool();
    return 0;
}

