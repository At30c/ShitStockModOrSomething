// Copyright (c) 2026 At30c
// SPDX-License-Identifier: GPL-3.0-or-later
#include <android/hardware/graphics/mapper/IMapper.h>
#include <hardware/gralloc1.h>
#include <linux/dma-buf.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <system/graphics.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <string_view>
#include <time.h>
#include <vector>

#include "exynos990/graphics_backend.h"
#include "exynos990/camera_aidl_mapper.h"
#include "exynos990/graphics_contract.h"
#include "exynos990/y2s_modifier.h"
#include "metadata.h"

namespace {

extern "C" int __android_log_print(int priority, const char* tag, const char* format, ...);
#define ALOGI(...) __android_log_print(4, "Exynos990MapperBridge", __VA_ARGS__)
#define ALOGE(...) __android_log_print(6, "Exynos990MapperBridge", __VA_ARGS__)

using exynos990::metadata::Writer;

AIMapper_Error convert(int32_t error) {
    switch (error) {
        case GRALLOC1_ERROR_NONE: return AIMAPPER_ERROR_NONE;
        case GRALLOC1_ERROR_BAD_DESCRIPTOR: return AIMAPPER_ERROR_BAD_DESCRIPTOR;
        case GRALLOC1_ERROR_BAD_HANDLE: return AIMAPPER_ERROR_BAD_BUFFER;
        case GRALLOC1_ERROR_BAD_VALUE: return AIMAPPER_ERROR_BAD_VALUE;
        case GRALLOC1_ERROR_NO_RESOURCES: return AIMAPPER_ERROR_NO_RESOURCES;
        default: return AIMAPPER_ERROR_UNSUPPORTED;
    }
}

using Bridge = exynos990_gralloc_backend_t;

Bridge& bridge() {
    return *const_cast<Bridge*>(exynos990_gralloc_backend());
}

// Match the ownership checks used by AOSP's HIDL mapper passthrough. Stable-C
// callers may only operate on handles returned by this mapper instance and
// must release each imported handle exactly once.
class ImportedBufferPool {
  public:
    bool add(buffer_handle_t buffer, uint64_t backingStore) {
        pthread_mutex_lock(&mutex_);
        Node** bucket = &buckets_[bucketFor(buffer)];
        for (Node* node = *bucket; node; node = node->next) {
            if (node->buffer == buffer) {
                pthread_mutex_unlock(&mutex_);
                return false;
            }
        }
        Node* node = new (std::nothrow) Node;
        if (!node) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        node->buffer = buffer;
        node->backingStore = backingStore;
        node->next = *bucket;
        *bucket = node;
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool contains(buffer_handle_t buffer) const {
        pthread_mutex_lock(&mutex_);
        const Node* node = buckets_[bucketFor(buffer)];
        while (node && node->buffer != buffer) node = node->next;
        pthread_mutex_unlock(&mutex_);
        return node != nullptr;
    }

    bool remove(buffer_handle_t buffer) {
        pthread_mutex_lock(&mutex_);
        Node** link = &buckets_[bucketFor(buffer)];
        while (*link && (*link)->buffer != buffer) link = &(*link)->next;
        if (!*link) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        Node* removed = *link;
        *link = removed->next;
        delete removed;
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool markLocked(buffer_handle_t buffer) {
        pthread_mutex_lock(&mutex_);
        Node* node = findLocked(buffer);
        if (!node) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        ++node->lockCount;
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool markUnlocked(buffer_handle_t buffer) {
        pthread_mutex_lock(&mutex_);
        Node* node = findLocked(buffer);
        if (!node || node->lockCount == 0) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        --node->lockCount;
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool isLocked(buffer_handle_t buffer) const {
        pthread_mutex_lock(&mutex_);
        const Node* node = findLocked(buffer);
        const bool locked = node && node->lockCount != 0;
        pthread_mutex_unlock(&mutex_);
        return locked;
    }

    bool setMetadata(buffer_handle_t buffer, int64_t type, const void* data, size_t size) {
        // A zero-length blob is valid, but a non-empty blob must always have
        // storage.  Avoid forming a pointer range from nullptr below; that is
        // undefined even before vector::assign gets a chance to reject it.
        if (size != 0 && !data) return false;
        pthread_mutex_lock(&mutex_);
        Node* node = findMetadataNodeLocked(buffer);
        if (!node) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        for (Node* bucket : buckets_) {
            for (Node* current = bucket; current; current = current->next) {
                if (!sameMetadataOwner(node, current)) continue;
                bool replaced = false;
                for (MetadataBlob& blob : current->metadata) {
                    if (blob.type == type) {
                        blob.value.assign(static_cast<const uint8_t*>(data),
                                          static_cast<const uint8_t*>(data) + size);
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    MetadataBlob blob;
                    blob.type = type;
                    blob.value.assign(static_cast<const uint8_t*>(data),
                                      static_cast<const uint8_t*>(data) + size);
                    current->metadata.emplace_back(std::move(blob));
                }
            }
        }
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool clearMetadata(buffer_handle_t buffer, int64_t type) {
        pthread_mutex_lock(&mutex_);
        Node* node = findMetadataNodeLocked(buffer);
        if (!node) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        for (Node* bucket : buckets_) {
            for (Node* current = bucket; current; current = current->next) {
                if (!sameMetadataOwner(node, current)) continue;
                const auto it = std::remove_if(
                        current->metadata.begin(), current->metadata.end(),
                        [type](const MetadataBlob& blob) { return blob.type == type; });
                current->metadata.erase(it, current->metadata.end());
            }
        }
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool getMetadata(buffer_handle_t buffer, int64_t type, std::vector<uint8_t>* output) const {
        if (!output) return false;
        pthread_mutex_lock(&mutex_);
        const Node* node = findMetadataNodeLocked(buffer);
        if (!node) {
            pthread_mutex_unlock(&mutex_);
            return false;
        }
        for (const MetadataBlob& blob : node->metadata) {
            if (blob.type == type) {
                *output = blob.value;
                pthread_mutex_unlock(&mutex_);
                return true;
            }
        }
        pthread_mutex_unlock(&mutex_);
        return false;
    }

    void snapshot(std::vector<buffer_handle_t>* output) const {
        if (!output) return;
        output->clear();
        pthread_mutex_lock(&mutex_);
        for (Node* bucket : buckets_) {
            for (Node* node = bucket; node; node = node->next) output->push_back(node->buffer);
        }
        pthread_mutex_unlock(&mutex_);
    }

  private:
    struct MetadataBlob {
        int64_t type = 0;
        std::vector<uint8_t> value;
    };

    struct Node {
        buffer_handle_t buffer = nullptr;
        uint64_t backingStore = 0;
        uint32_t lockCount = 0;
        std::vector<MetadataBlob> metadata;
        Node* next = nullptr;
    };

    Node* findLocked(buffer_handle_t buffer) const {
        Node* node = buckets_[bucketFor(buffer)];
        while (node && node->buffer != buffer) node = node->next;
        return node;
    }

    static bool sameBackingStore(const Node* first, const Node* second) {
        return first && second && first->backingStore != 0 &&
               first->backingStore == second->backingStore;
    }

    // Some legacy gralloc implementations legitimately return zero from
    // GET_BACKING_STORE.  Metadata still belongs to that exact imported
    // handle; using only sameBackingStore() silently dropped every set() on
    // those drivers.  Handles with a real backing-store id continue to share
    // metadata across imports of the same allocation.
    static bool sameMetadataOwner(const Node* first, const Node* second) {
        if (!first || !second) return false;
        return first == second || sameBackingStore(first, second);
    }

    Node* findMetadataNodeLocked(buffer_handle_t buffer) const {
        Node* node = findLocked(buffer);
        if (!node) return nullptr;
        if (node->backingStore == 0) return node;
        for (Node* bucket : buckets_) {
            for (Node* current = bucket; current; current = current->next) {
                if (sameBackingStore(node, current)) return current;
            }
        }
        return node;
    }

    static constexpr size_t kBucketCount = 256;

    static size_t bucketFor(buffer_handle_t buffer) {
        return (reinterpret_cast<uintptr_t>(buffer) >> 4) & (kBucketCount - 1);
    }

    mutable pthread_mutex_t mutex_ = PTHREAD_MUTEX_INITIALIZER;
    Node* buckets_[kBucketCount] = {};
};

ImportedBufferPool& importedBuffers() {
    // GraphicBufferMapper is intentionally process-lifetime state.  Keeping
    // this pool alive avoids destructor ordering against the dlopened gralloc.
    static ImportedBufferPool* pool = new ImportedBufferPool;
    return *pool;
}

// The original Exynos 990 camera gralloc uses a private 0x11d format whose
// Y and chroma planes live in different DMA-BUFs.  Android 17's camera helper
// writes the result of ANativeWindow::lock() as one contiguous Y + UV image.
// Keep the vendor layout intact and bridge only the CPU lock with a temporary
// linear buffer.  The plane pointers below come exclusively from the y2s
// driver's LOCK_FLEX callback; no SGR/private-handle offsets are used here.
class CameraLinearLockPool {
  public:
    struct Entry {
        buffer_handle_t buffer = nullptr;
        void* linear = nullptr;
        size_t linearSize = 0;
        void* y = nullptr;
        void* chroma = nullptr;
        int32_t yStride = 0;
        int32_t chromaStride = 0;
        uint32_t width = 0;
        uint32_t height = 0;
        uint32_t sequence = 0;
        uint64_t lockStartNs = 0;
        bool write = false;
        uint32_t depth = 1;
    };

    // GraphicBufferMapper can acquire the same private camera handle more
    // than once before releasing it.  The stock Gralloc1 callback is still
    // balanced once per acquisition, but all nested callers must see the
    // same contiguous address.  Returning a new scratch allocation for each
    // lock loses the writes when the inner lock is released first.
    enum class ReuseResult { kMissing, kReused, kMismatch };

    ReuseResult reuse(const Entry& candidate, void** output) {
        if (!output) return ReuseResult::kMismatch;
        pthread_mutex_lock(&mutex_);
        Entry* entry = findLatestLocked(candidate.buffer);
        if (!entry) {
            pthread_mutex_unlock(&mutex_);
            return ReuseResult::kMissing;
        }
        if (entry->width != candidate.width || entry->height != candidate.height ||
            entry->yStride != candidate.yStride ||
            entry->chromaStride != candidate.chromaStride || entry->y != candidate.y ||
            entry->chroma != candidate.chroma || entry->linearSize != candidate.linearSize) {
            pthread_mutex_unlock(&mutex_);
            return ReuseResult::kMismatch;
        }
        entry->write = entry->write || candidate.write;
        ++entry->depth;
        *output = entry->linear;
        pthread_mutex_unlock(&mutex_);
        return ReuseResult::kReused;
    }

    bool add(const Entry& entry) {
        pthread_mutex_lock(&mutex_);
        entries_.push_back(entry);
        pthread_mutex_unlock(&mutex_);
        return true;
    }

    bool get(buffer_handle_t buffer, Entry* output) const {
        if (!output) return false;
        pthread_mutex_lock(&mutex_);
        const Entry* entry = findLatestLocked(buffer);
        if (entry) *output = *entry;
        pthread_mutex_unlock(&mutex_);
        return entry != nullptr;
    }

    bool remove(buffer_handle_t buffer, Entry* output) {
        pthread_mutex_lock(&mutex_);
        for (auto it = entries_.end(); it != entries_.begin();) {
            --it;
            if (it->buffer != buffer) continue;
            if (output) *output = *it;
            entries_.erase(it);
            pthread_mutex_unlock(&mutex_);
            return true;
        }
        pthread_mutex_unlock(&mutex_);
        return false;
    }

    bool isFinal(buffer_handle_t buffer) const {
        pthread_mutex_lock(&mutex_);
        const Entry* entry = findLatestLocked(buffer);
        const bool result = entry && entry->depth == 1;
        pthread_mutex_unlock(&mutex_);
        return result;
    }

    bool release(buffer_handle_t buffer, Entry* output, bool* final) {
        if (final) *final = false;
        pthread_mutex_lock(&mutex_);
        for (auto it = entries_.end(); it != entries_.begin();) {
            --it;
            if (it->buffer != buffer) continue;
            if (it->depth > 1) {
                --it->depth;
                if (output) *output = *it;
                pthread_mutex_unlock(&mutex_);
                return true;
            }
            if (output) *output = *it;
            entries_.erase(it);
            if (final) *final = true;
            pthread_mutex_unlock(&mutex_);
            return true;
        }
        pthread_mutex_unlock(&mutex_);
        return false;
    }

  private:
    Entry* findLatestLocked(buffer_handle_t buffer) const {
        for (auto it = entries_.rbegin(); it != entries_.rend(); ++it) {
            if (it->buffer == buffer) return &*it;
        }
        return nullptr;
    }

    mutable pthread_mutex_t mutex_ = PTHREAD_MUTEX_INITIALIZER;
    mutable std::vector<Entry> entries_;
};

CameraLinearLockPool& cameraLinearLocks() {
    static CameraLinearLockPool* pool = new CameraLinearLockPool;
    return *pool;
}

uint64_t monotonicNs() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL +
            static_cast<uint64_t>(ts.tv_nsec);
}

uint64_t elapsedMs(uint64_t start, uint64_t end) {
    return end >= start ? (end - start) / 1000000ULL : 0;
}

std::atomic<uint32_t>& cameraLockSequence() {
    static std::atomic<uint32_t> sequence{0};
    return sequence;
}

void closeScratch(const CameraLinearLockPool::Entry& entry) {
    if (entry.linear && entry.linearSize) munmap(entry.linear, entry.linearSize);
}

void copyLinearToPlanes(const CameraLinearLockPool::Entry& entry) {
    if (!entry.linear || !entry.y || !entry.chroma || entry.width == 0 ||
        entry.height == 0 || entry.yStride <= 0 || entry.chromaStride <= 0) return;
    const size_t yRowBytes = std::min<size_t>(entry.width, entry.yStride);
    const size_t chromaRowBytes = std::min<size_t>(entry.width, entry.chromaStride);
    const uint8_t* linear = static_cast<const uint8_t*>(entry.linear);
    uint8_t* y = static_cast<uint8_t*>(entry.y);
    uint8_t* chroma = static_cast<uint8_t*>(entry.chroma);
    for (uint32_t row = 0; row < entry.height; ++row) {
        std::memcpy(y + static_cast<size_t>(row) * entry.yStride,
                    linear + static_cast<size_t>(row) * entry.yStride, yRowBytes);
    }
    const size_t yBytes = static_cast<size_t>(entry.yStride) * entry.height;
    const uint32_t chromaHeight = (entry.height + 1) / 2;
    for (uint32_t row = 0; row < chromaHeight; ++row) {
        std::memcpy(chroma + static_cast<size_t>(row) * entry.chromaStride,
                    linear + yBytes + static_cast<size_t>(row) * entry.chromaStride,
                    chromaRowBytes);
    }
}

void copyPlanesToLinear(const CameraLinearLockPool::Entry& entry) {
    if (!entry.linear || !entry.y || !entry.chroma || entry.width == 0 ||
        entry.height == 0 || entry.yStride <= 0 || entry.chromaStride <= 0) return;
    const size_t yRowBytes = std::min<size_t>(entry.width, entry.yStride);
    const size_t chromaRowBytes = std::min<size_t>(entry.width, entry.chromaStride);
    const uint8_t* y = static_cast<const uint8_t*>(entry.y);
    const uint8_t* chroma = static_cast<const uint8_t*>(entry.chroma);
    uint8_t* linear = static_cast<uint8_t*>(entry.linear);
    for (uint32_t row = 0; row < entry.height; ++row) {
        std::memcpy(linear + static_cast<size_t>(row) * entry.yStride,
                    y + static_cast<size_t>(row) * entry.yStride, yRowBytes);
    }
    const size_t yBytes = static_cast<size_t>(entry.yStride) * entry.height;
    const uint32_t chromaHeight = (entry.height + 1) / 2;
    for (uint32_t row = 0; row < chromaHeight; ++row) {
        std::memcpy(linear + yBytes + static_cast<size_t>(row) * entry.chromaStride,
                    chroma + static_cast<size_t>(row) * entry.chromaStride,
                    chromaRowBytes);
    }
}

bool isImported(buffer_handle_t buffer) {
    return buffer && importedBuffers().contains(buffer);
}

bool isValidRawHandle(const native_handle_t* handle) {
    if (!handle || handle->version != sizeof(native_handle_t) ||
        handle->numFds < 0 || handle->numInts < 0 ||
        handle->numFds > NATIVE_HANDLE_MAX_FDS ||
        handle->numInts > NATIVE_HANDLE_MAX_INTS) {
        return false;
    }
    // Keep the addition in a bounded type before native_handle_clone() walks
    // the payload.  The individual limits above also match Android's native
    // handle ABI and reject truncated/corrupt transport blobs.
    const size_t payload = static_cast<size_t>(handle->numFds) +
            static_cast<size_t>(handle->numInts);
    return payload <= static_cast<size_t>(NATIVE_HANDLE_MAX_FDS) +
            static_cast<size_t>(NATIVE_HANDLE_MAX_INTS);
}

bool readHandleU32(buffer_handle_t buffer, size_t byteOffset, uint32_t* value) {
    if (!buffer || !value || buffer->numFds < 0 || buffer->numInts < 0) return false;
    const size_t bytes = offsetof(native_handle_t, data) +
            static_cast<size_t>(buffer->numFds + buffer->numInts) * sizeof(int);
    if (byteOffset > bytes || sizeof(*value) > bytes - byteOffset) return false;
    std::memcpy(value, reinterpret_cast<const uint8_t*>(buffer) + byteOffset, sizeof(*value));
    return true;
}

// IMPLEMENTATION_DEFINED com usage de câmera (por exemplo o ImageReader
// 0x22/0x20933 do Motion Photo) é alocado pelo Mali como o YUV privado 0x11d:
// mesmo NV21 com Y e croma em DMA-BUFs separados. O formato de framework não
// revela isso; só o allocation format (+0x50) do handle.
bool isImplementationDefinedCameraYuv(buffer_handle_t buffer, int32_t format) {
    uint32_t allocation = 0;
    return format == HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED &&
            readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kAllocationFormat,
                          &allocation) &&
            exynos990::graphics::isExynosPrivateCameraYuv(static_cast<int32_t>(allocation));
}

// Strides publicados no PLANE_LAYOUTS desses buffers. O lock confere que o
// LOCK_FLEX devolve os mesmos valores antes de entregar o scratch linear.
bool readCameraYuvStrides(buffer_handle_t buffer, uint32_t* yStride, uint32_t* chromaStride) {
    return readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kYStride, yStride) &&
            readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kChromaStride,
                          chromaStride) &&
            *yStride != 0 && *chromaStride != 0;
}

AIMapper_Error lockCameraPrivateYuv(buffer_handle_t buffer, uint64_t legacyUsage,
                                    const gralloc1_rect_t& region, int fence, void** output,
                                    bool publishedLayout) {
    uint32_t width = 0, height = 0, stride = 0;
    if (bridge().getDimensions(bridge().device, buffer, &width, &height) != GRALLOC1_ERROR_NONE ||
        bridge().getStride(bridge().device, buffer, &stride) != GRALLOC1_ERROR_NONE ||
        width == 0 || height == 0 || stride == 0 ||
        region.left != 0 || region.top != 0 ||
        region.width != static_cast<int32_t>(width) ||
        region.height != static_cast<int32_t>(height)) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_UNSUPPORTED;
    }

    // This is the original y2s Camera3 mapper contract, not the Gralloc1
    // callback contract: private_module_t is null and usage is the legacy
    // combined Android mask.  Keeping it verbatim matters for 0x11d, whose
    // Y/Cb/Cr DMA-BUF layout is owned by the Mali camera helpers.
    if (!bridge().cameraReady || !bridge().cameraGetNumFlexPlanes ||
        !bridge().cameraLockFlexAsync || !bridge().cameraUnlock) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_UNSUPPORTED;
    }
    uint32_t planeCount = 0;
    AIMapper_Error error = convert(bridge().cameraGetNumFlexPlanes(
            nullptr, buffer, &planeCount));
    if (error != AIMAPPER_ERROR_NONE || planeCount == 0 || planeCount > 8) {
        if (fence >= 0) close(fence);
        return error == AIMAPPER_ERROR_NONE ? AIMAPPER_ERROR_BAD_BUFFER : error;
    }
    std::vector<android_flex_plane_t> planes(planeCount);
    android_flex_layout_t layout{
            .format = FLEX_FORMAT_INVALID,
            .num_planes = planeCount,
            .planes = planes.data(),
    };
    const uint64_t lockStartNs = monotonicNs();
    error = convert(bridge().cameraLockFlexAsync(
            nullptr, buffer, legacyUsage, region.left, region.top, region.width,
            region.height, &layout, fence));
    const uint64_t lockFlexDoneNs = monotonicNs();
    if (error != AIMAPPER_ERROR_NONE) {
        ALOGI("Camera mapper lockFlex failed: error=%d elapsed=%llums",
              error, static_cast<unsigned long long>(elapsedMs(lockStartNs, lockFlexDoneNs)));
        return error;
    }

    const android_flex_plane_t* yPlane = nullptr;
    const android_flex_plane_t* cbPlane = nullptr;
    const android_flex_plane_t* crPlane = nullptr;
    for (uint32_t index = 0; index < layout.num_planes; ++index) {
        const android_flex_plane_t& plane = layout.planes[index];
        if (!plane.top_left || plane.h_increment <= 0 || plane.v_increment <= 0) continue;
        if (plane.component == FLEX_COMPONENT_Y) yPlane = &plane;
        if (plane.component == FLEX_COMPONENT_Cb) cbPlane = &plane;
        if (plane.component == FLEX_COMPONENT_Cr) crPlane = &plane;
    }
    // The 0x11d handle observed on the y2s is NV21-like: Cb and Cr are
    // adjacent bytes in one interleaved plane. Reject any other description
    // rather than guessing a layout from the S26+ mapper.
    if (!yPlane || !cbPlane || !crPlane ||
        cbPlane->h_increment != 2 || crPlane->h_increment != 2 ||
        cbPlane->v_increment <= 0 || cbPlane->v_increment != crPlane->v_increment ||
        std::llabs(reinterpret_cast<intptr_t>(cbPlane->top_left) -
                   reinterpret_cast<intptr_t>(crPlane->top_left)) != 1) {
        (void)bridge().cameraUnlock(nullptr, buffer);
        return AIMAPPER_ERROR_UNSUPPORTED;
    }
    // Para IMPLEMENTATION_DEFINED o Gralloc5 monta android_ycbcr a partir do
    // PLANE_LAYOUTS lido antes deste lock (NV21 com os strides do handle). O
    // scratch só é entregue se o LOCK_FLEX descrever exatamente essa memória.
    if (publishedLayout) {
        uint32_t handleYStride = 0, handleChromaStride = 0;
        if (!readCameraYuvStrides(buffer, &handleYStride, &handleChromaStride) ||
            static_cast<uint32_t>(yPlane->v_increment) != handleYStride ||
            static_cast<uint32_t>(cbPlane->v_increment) != handleChromaStride ||
            reinterpret_cast<uintptr_t>(crPlane->top_left) >
                    reinterpret_cast<uintptr_t>(cbPlane->top_left)) {
            ALOGE("Camera YUV layout mismatch: yInc=%d chromaInc=%d handle=%u/%u",
                  yPlane->v_increment, cbPlane->v_increment, handleYStride, handleChromaStride);
            (void)bridge().cameraUnlock(nullptr, buffer);
            return AIMAPPER_ERROR_UNSUPPORTED;
        }
    }

    const size_t yStride = static_cast<size_t>(yPlane->v_increment);
    const size_t chromaStride = static_cast<size_t>(cbPlane->v_increment);
    const uint32_t chromaHeight = (height + 1) / 2;
    if (yStride == 0 || chromaStride == 0 ||
        yStride > std::numeric_limits<size_t>::max() / height ||
        chromaStride > std::numeric_limits<size_t>::max() / chromaHeight) {
        (void)bridge().cameraUnlock(nullptr, buffer);
        return AIMAPPER_ERROR_NO_RESOURCES;
    }
    const size_t yBytes = yStride * height;
    const size_t chromaBytes = chromaStride * chromaHeight;
    if (yBytes > std::numeric_limits<size_t>::max() - chromaBytes) {
        (void)bridge().cameraUnlock(nullptr, buffer);
        return AIMAPPER_ERROR_NO_RESOURCES;
    }
    const size_t total = yBytes + chromaBytes;
    CameraLinearLockPool::Entry candidate;
    candidate.buffer = buffer;
    candidate.linearSize = total;
    candidate.y = yPlane->top_left;
    candidate.chroma = reinterpret_cast<uintptr_t>(cbPlane->top_left) <
                    reinterpret_cast<uintptr_t>(crPlane->top_left)
            ? cbPlane->top_left : crPlane->top_left;
    candidate.yStride = yPlane->v_increment;
    candidate.chromaStride = cbPlane->v_increment;
    candidate.width = width;
    candidate.height = height;
    candidate.sequence = cameraLockSequence().fetch_add(1, std::memory_order_relaxed) + 1;
    candidate.lockStartNs = lockStartNs;
    candidate.write = (legacyUsage & exynos990::graphics::kAidlCpuWriteMask) != 0;
    if (candidate.sequence <= 4) {
        const auto byteAt = [](const void* address) -> unsigned int {
            return address ? static_cast<unsigned int>(*static_cast<const uint8_t*>(address)) : 0U;
        };
        ALOGI("Camera mapper private layout seq=%u fmt=%d planes=%u y=%p yInc=%d/%d cb=%p cbInc=%d/%d cr=%p crInc=%d/%d y0=%u cb0=%u cr0=%u total=%zu",
              candidate.sequence, layout.format, layout.num_planes,
              yPlane->top_left, yPlane->h_increment, yPlane->v_increment,
              cbPlane->top_left, cbPlane->h_increment, cbPlane->v_increment,
              crPlane->top_left, crPlane->h_increment, crPlane->v_increment,
              byteAt(yPlane->top_left), byteAt(cbPlane->top_left),
              byteAt(crPlane->top_left), total);
    }

    void* reused = nullptr;
    const auto reuse = cameraLinearLocks().reuse(candidate, &reused);
    if (reuse == CameraLinearLockPool::ReuseResult::kReused) {
        *output = reused;
        const uint64_t nowNs = monotonicNs();
        if (candidate.sequence <= 4 || elapsedMs(lockStartNs, nowNs) >= 20) {
            ALOGI("Camera mapper nested lock seq=%u lockFlex=%llums total=%llums",
                  candidate.sequence,
                  static_cast<unsigned long long>(elapsedMs(lockStartNs, lockFlexDoneNs)),
                  static_cast<unsigned long long>(elapsedMs(lockStartNs, nowNs)));
        }
        return AIMAPPER_ERROR_NONE;
    }
    if (reuse == CameraLinearLockPool::ReuseResult::kMismatch) {
        (void)bridge().cameraUnlock(nullptr, buffer);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }

    void* linear = mmap(nullptr, total, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (linear == MAP_FAILED) {
        (void)bridge().cameraUnlock(nullptr, buffer);
        return AIMAPPER_ERROR_NO_RESOURCES;
    }

    CameraLinearLockPool::Entry entry = candidate;
    entry.linear = linear;
    const uint64_t copyStartNs = monotonicNs();
    // Só um lock exclusivamente de escrita pode começar com o scratch vazio.
    // A libsume bloqueia sempre com CPU_READ|CPU_WRITE (0x33), inclusive ao
    // ler o ImageReader do Motion Photo; pular a cópia nesse caso entregava
    // quadros zerados (verdes) ao encoder.
    if (legacyUsage & exynos990::graphics::kAidlCpuReadMask) copyPlanesToLinear(entry);
    const uint64_t copyDoneNs = monotonicNs();
    if (!cameraLinearLocks().add(entry)) {
        closeScratch(entry);
        (void)bridge().cameraUnlock(nullptr, buffer);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    *output = linear;
    if (entry.sequence <= 4 || elapsedMs(lockStartNs, copyDoneNs) >= 20) {
        ALOGI("Camera mapper lock seq=%u lockFlex=%llums copy=%llums total=%llums size=%zu write=%d",
              entry.sequence,
              static_cast<unsigned long long>(elapsedMs(lockStartNs, lockFlexDoneNs)),
              static_cast<unsigned long long>(elapsedMs(copyStartNs, copyDoneNs)),
              static_cast<unsigned long long>(elapsedMs(lockStartNs, copyDoneNs)),
              entry.linearSize, entry.write ? 1 : 0);
    }
    return AIMAPPER_ERROR_NONE;
}

void closeImportedHandle(buffer_handle_t buffer) {
    native_handle_close(buffer);
    native_handle_delete(const_cast<native_handle_t*>(buffer));
}

AIMapper_Error releaseImportedHandle(buffer_handle_t buffer) {
    const AIMapper_Error error = convert(bridge().release(bridge().device, buffer));
    if (error == AIMAPPER_ERROR_NONE && !bridge().releaseImpliesDelete) {
        closeImportedHandle(buffer);
    }
    return error;
}

AIMapper_Error importBuffer(const native_handle_t* raw, buffer_handle_t* output) {
    if (output) *output = nullptr;
    if (!isValidRawHandle(raw) || !output || !bridge().ready)
        return AIMAPPER_ERROR_BAD_BUFFER;
    native_handle_t* imported = native_handle_clone(raw);
    if (!imported) return AIMAPPER_ERROR_NO_RESOURCES;
    const AIMapper_Error error = convert(bridge().retain(bridge().device, imported));
    if (error != AIMAPPER_ERROR_NONE) {
        closeImportedHandle(imported);
        return error;
    }
    uint64_t backingStore = 0;
    (void)bridge().backingStore(bridge().device, imported, &backingStore);
    if (!importedBuffers().add(imported, backingStore)) {
        releaseImportedHandle(imported);
        return AIMAPPER_ERROR_NO_RESOURCES;
    }
    *output = imported;
    return AIMAPPER_ERROR_NONE;
}

AIMapper_Error freeBuffer(buffer_handle_t buffer) {
    if (!buffer || !bridge().ready || !isImported(buffer)) return AIMAPPER_ERROR_BAD_BUFFER;
    if (importedBuffers().isLocked(buffer)) return AIMAPPER_ERROR_BAD_BUFFER;
    const AIMapper_Error error = releaseImportedHandle(buffer);
    if (error == AIMAPPER_ERROR_NONE) importedBuffers().remove(buffer);
    return error;
}

// Camera3 keeps the historical HIDL import/free ownership contract even when
// the framework reaches the camera through the AIDL provider.  Export the same
// clone + Gralloc1 retain/release path used by Stable-C so the camera bridge
// never has to load a HIDL implementation from outside the vendor namespace.
extern "C" __attribute__((visibility("default"))) int exynos990_aidl_camera_import(
        const native_handle_t* raw, buffer_handle_t* output) {
    return static_cast<int>(importBuffer(raw, output));
}

extern "C" __attribute__((visibility("default"))) int exynos990_aidl_camera_free(
        buffer_handle_t buffer) {
    return static_cast<int>(freeBuffer(buffer));
}

AIMapper_Error getTransportSize(buffer_handle_t buffer, uint32_t* fds, uint32_t* ints) {
    if (!isImported(buffer) || !fds || !ints || !bridge().ready)
        return AIMAPPER_ERROR_BAD_BUFFER;
    return convert(bridge().transportSize(bridge().device, buffer, fds, ints));
}

AIMapper_Error lockBuffer(buffer_handle_t buffer, uint64_t usage, ARect rect, int fence,
                          void** output) {
    if (!isImported(buffer) || !output || !bridge().ready) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    // IMapper defines an all-zero access region as the complete allocation.
    // The private camera format cannot safely expose a cropped linear scratch
    // buffer, so normalize that form before entering either lock path.
    uint32_t bufferWidth = 0, bufferHeight = 0;
    if (bridge().getDimensions(bridge().device, buffer, &bufferWidth, &bufferHeight) !=
        GRALLOC1_ERROR_NONE || bufferWidth == 0 || bufferHeight == 0 ||
        bufferWidth > INT32_MAX || bufferHeight > INT32_MAX) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    if (rect.left == 0 && rect.top == 0 && rect.right == 0 && rect.bottom == 0) {
        rect.right = static_cast<int32_t>(bufferWidth);
        rect.bottom = static_cast<int32_t>(bufferHeight);
    }
    const int64_t regionWidth = static_cast<int64_t>(rect.right) - rect.left;
    const int64_t regionHeight = static_cast<int64_t>(rect.bottom) - rect.top;
    if (rect.left < 0 || rect.top < 0 || rect.right <= rect.left || rect.bottom <= rect.top ||
        static_cast<int64_t>(rect.right) > static_cast<int64_t>(bufferWidth) ||
        static_cast<int64_t>(rect.bottom) > static_cast<int64_t>(bufferHeight) ||
        regionWidth > INT32_MAX || regionHeight > INT32_MAX) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_BAD_VALUE;
    }
    gralloc1_rect_t region = {
            .left = rect.left,
            .top = rect.top,
            .width = static_cast<int32_t>(regionWidth),
            .height = static_cast<int32_t>(regionHeight),
    };
    // Protected camera/video allocations are intentionally never CPU-mapped.
    // This is the same boundary used by the S26+ Stable-C mapper: the
    // allocator may create a protected handle, but IMapper::lock() must not
    // expose its contents or pass it through the temporary 0x11d scratch
    // path.  Report an explicit unsupported operation and consume the fence.
    if (usage & exynos990::graphics::kAidlProtected) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_UNSUPPORTED;
    }
    // Gralloc1 requires exactly one CPU access side. A write lock is a
    // producer operation (and also permits reads by the same CPU caller);
    // a read-only lock is a consumer operation.
    // Clients lock with the usage the buffer was created with: an ImageReader
    // made for RenderScript (CPU_READ_OFTEN | RENDERSCRIPT, as the FaceTec
    // liveness SDK of banking apps does) passes 0x100003 through AImage. Like
    // the stock gralloc, use only the CPU bits of a lock request; rejecting the
    // others made every frame of those readers fail with BAD_VALUE.
    const uint64_t cpuMask = exynos990::graphics::kAidlCpuReadMask |
            exynos990::graphics::kAidlCpuWriteMask;
    usage &= cpuMask;
    const uint64_t cpuReadUsage = usage & exynos990::graphics::kAidlCpuReadMask;
    const uint64_t cpuWriteUsage = usage & exynos990::graphics::kAidlCpuWriteMask;
    if (cpuReadUsage == 0 && cpuWriteUsage == 0) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_BAD_VALUE;
    }
    const uint64_t producerUsage = cpuWriteUsage;
    const uint64_t consumerUsage = cpuWriteUsage != 0 ? 0 : cpuReadUsage;
    int32_t format = 0;
    const int32_t formatError = bridge().getFormat(bridge().device, buffer, &format);
    if (formatError != GRALLOC1_ERROR_NONE) {
        if (fence >= 0) close(fence);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }

    AIMapper_Error error = AIMAPPER_ERROR_NONE;
    const bool implementationDefinedCameraYuv = isImplementationDefinedCameraYuv(buffer, format);
    const bool privateCameraYuv = implementationDefinedCameraYuv ||
            exynos990::graphics::isExynosPrivateCameraYuv(format);
    if (privateCameraYuv) {
        // These private y2s camera formats are the paths where the original
        // gralloc's ordinary pointer is not compatible with Android 17's
        // contiguous YUV producer contract.  0x11d is preview/output and
        // 0x11e is the Motion Photo/filter NV21 side channel.  The latter is
        // explicitly rejected by Mali's ordinary lock(), so both must keep
        // the stock Camera3 LOCK_FLEX contract and use a temporary linear
        // allocation for a CPU client.  IMPLEMENTATION_DEFINED buffers backed
        // by the same allocation take this path as well.
        error = lockCameraPrivateYuv(buffer, usage, region, fence, output,
                                     implementationDefinedCameraYuv);
    }
    const bool flexibleYuv = format == HAL_PIXEL_FORMAT_YCBCR_420_888 ||
            format == HAL_PIXEL_FORMAT_YV12 || format == HAL_PIXEL_FORMAT_YCRCB_420_SP ||
            format == HAL_PIXEL_FORMAT_YCBCR_422_SP;
    if (privateCameraYuv) {
        // The private camera path already performed LOCK_FLEX.
        if (error != AIMAPPER_ERROR_NONE) return error;
    } else if (flexibleYuv) {
        uint32_t planeCount = 0;
        error = convert(bridge().getNumFlexPlanes(bridge().device, buffer, &planeCount));
        if (error != AIMAPPER_ERROR_NONE || planeCount == 0 || planeCount > 8) {
            if (fence >= 0) close(fence);
            return error == AIMAPPER_ERROR_NONE ? AIMAPPER_ERROR_BAD_BUFFER : error;
        }
        std::vector<android_flex_plane_t> planes(planeCount);
        android_flex_layout_t layout{
                .format = FLEX_FORMAT_INVALID,
                .num_planes = planeCount,
                .planes = planes.data(),
        };
        error = convert(bridge().lockFlex(bridge().device, buffer, producerUsage,
                                          consumerUsage, &region, &layout, fence));
        if (error == AIMAPPER_ERROR_NONE) {
            // Stable-C Mapper::lock() has one contract for both ordinary and
            // YUV locks: outData points to a single CPU-linear address.  The
            // framework's Gralloc4/5 wrapper calls this entry point first and
            // then builds android_ycbcr from PLANE_LAYOUTS.  Do not write an
            // android_ycbcr object through `output`; doing so overwrites the
            // caller's stack (and was the source of the dmabuf PC crash).
            const android_flex_plane_t* yPlane = nullptr;
            const android_flex_plane_t* cbPlane = nullptr;
            const android_flex_plane_t* crPlane = nullptr;
            for (uint32_t index = 0; index < layout.num_planes; ++index) {
                const android_flex_plane_t& plane = layout.planes[index];
                if (!plane.top_left || plane.h_increment <= 0 || plane.v_increment <= 0)
                    continue;
                if (plane.component == FLEX_COMPONENT_Y) yPlane = &plane;
                if (plane.component == FLEX_COMPONENT_Cb) cbPlane = &plane;
                if (plane.component == FLEX_COMPONENT_Cr) crPlane = &plane;
            }
            if (!yPlane || !cbPlane || !crPlane || cbPlane->h_increment != crPlane->h_increment ||
                cbPlane->v_increment != crPlane->v_increment) {
                int ignoredFence = -1;
                bridge().unlock(bridge().device, buffer, &ignoredFence);
                if (ignoredFence >= 0) close(ignoredFence);
                return AIMAPPER_ERROR_BAD_BUFFER;
            }
            *output = yPlane->top_left;
        }
    } else {
        error = convert(bridge().lock(bridge().device, buffer, producerUsage,
                                      consumerUsage, &region, output, fence));
    }
    if (error == AIMAPPER_ERROR_NONE && !importedBuffers().markLocked(buffer)) {
        int ignoredFence = -1;
        if (privateCameraYuv) {
            bridge().cameraUnlock(nullptr, buffer);
        } else {
            bridge().unlock(bridge().device, buffer, &ignoredFence);
        }
        if (ignoredFence >= 0) close(ignoredFence);
        CameraLinearLockPool::Entry removed;
        if (cameraLinearLocks().remove(buffer, &removed)) closeScratch(removed);
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    return error;
}

AIMapper_Error unlockBuffer(buffer_handle_t buffer, int* fence) {
    if (!isImported(buffer) || !fence || !bridge().ready || !importedBuffers().isLocked(buffer))
        return AIMAPPER_ERROR_BAD_BUFFER;
    CameraLinearLockPool::Entry linearEntry;
    const bool hasLinearEntry = cameraLinearLocks().get(buffer, &linearEntry);
    // Nested locks share one scratch address.  Only the final unlock copies
    // the completed frame back to the native planes; copying from and
    // unmapping the inner scratch would discard the outer caller's writes.
    const bool finalLinearUnlock = hasLinearEntry && cameraLinearLocks().isFinal(buffer);
    const uint64_t unlockStartNs = monotonicNs();
    if (finalLinearUnlock && linearEntry.write) copyLinearToPlanes(linearEntry);
    const uint64_t copyDoneNs = monotonicNs();
    AIMapper_Error error = AIMAPPER_ERROR_NONE;
    if (hasLinearEntry) {
        const int cameraError = bridge().cameraUnlock(nullptr, buffer);
        if (cameraError != GRALLOC1_ERROR_NONE) {
            error = convert(cameraError);
        }
        *fence = -1;  // The stock Camera mapper unlock has no release-fence return.
    } else {
        error = convert(bridge().unlock(bridge().device, buffer, fence));
    }
    const uint64_t unlockDoneNs = monotonicNs();
    if (error == AIMAPPER_ERROR_NONE && !importedBuffers().markUnlocked(buffer)) {
        if (*fence >= 0) {
            close(*fence);
            *fence = -1;
        }
        return AIMAPPER_ERROR_BAD_BUFFER;
    }
    if (error == AIMAPPER_ERROR_NONE && hasLinearEntry) {
        CameraLinearLockPool::Entry removed;
        bool final = false;
        if (cameraLinearLocks().release(buffer, &removed, &final) && final) closeScratch(removed);
    }
    if (hasLinearEntry && finalLinearUnlock &&
        (linearEntry.sequence <= 4 || elapsedMs(unlockStartNs, unlockDoneNs) >= 20)) {
        ALOGI("Camera mapper unlock seq=%u copy=%llums grallocUnlock=%llums total=%llums error=%d",
              linearEntry.sequence,
              static_cast<unsigned long long>(elapsedMs(unlockStartNs, copyDoneNs)),
              static_cast<unsigned long long>(elapsedMs(copyDoneNs, unlockDoneNs)),
              static_cast<unsigned long long>(elapsedMs(unlockStartNs, unlockDoneNs)), error);
    }
    return error;
}

AIMapper_Error syncLockedBuffer(buffer_handle_t buffer, bool reread) {
    if (!isImported(buffer) || !bridge().ready || !importedBuffers().isLocked(buffer))
        return AIMAPPER_ERROR_BAD_BUFFER;

    CameraLinearLockPool::Entry linearEntry;
    if (cameraLinearLocks().get(buffer, &linearEntry)) {
        if (reread) {
            copyPlanesToLinear(linearEntry);
        } else if (linearEntry.write) {
            copyLinearToPlanes(linearEntry);
        }
        // LOCK_FLEX already performed the vendor cache maintenance.  The
        // scratch mapping has no DMA-BUF fd of its own, so there is no ioctl
        // to issue for it here.
        return AIMAPPER_ERROR_NONE;
    }

    // Gralloc1's lock path already performs the driver's normal cache maintenance.  The
    // dma-buf sync ioctl is an additional, ABI-stable barrier for buffers whose backing
    // allocator exposes explicit CPU cache operations.  Unsupported ioctls are ignored:
    // older Exynos ION buffers are coherent from the CPU's point of view and have no ioctl.
    const native_handle_t* handle = buffer;
    const unsigned long direction = reread ? DMA_BUF_SYNC_READ : DMA_BUF_SYNC_WRITE;
    const unsigned long end = direction | DMA_BUF_SYNC_END;
    const unsigned long start = direction | DMA_BUF_SYNC_START;
    for (int index = 0; index < handle->numFds; ++index) {
        if (handle->data[index] < 0) continue;
        dma_buf_sync sync{end};
        if (ioctl(handle->data[index], DMA_BUF_IOCTL_SYNC, &sync) != 0) {
            continue;
        }
        sync.flags = start;
        (void)ioctl(handle->data[index], DMA_BUF_IOCTL_SYNC, &sync);
    }
    return AIMAPPER_ERROR_NONE;
}

constexpr char kCompressionName[] =
        "android.hardware.graphics.common.Compression";
constexpr char kInterlacedName[] =
        "android.hardware.graphics.common.Interlaced";
constexpr char kChromaSitingName[] =
        "android.hardware.graphics.common.ChromaSiting";
constexpr char kPlaneComponentName[] =
        "android.hardware.graphics.common.PlaneLayoutComponentType";

uint32_t fourcc(char a, char b, char c, char d) {
    return static_cast<uint32_t>(a) | (static_cast<uint32_t>(b) << 8) |
           (static_cast<uint32_t>(c) << 16) | (static_cast<uint32_t>(d) << 24);
}

uint32_t pixelFormatFourcc(int32_t format) {
    switch (format) {
        case HAL_PIXEL_FORMAT_RGBA_8888: return fourcc('A', 'B', '2', '4');
        case HAL_PIXEL_FORMAT_RGBX_8888: return fourcc('X', 'B', '2', '4');
        case HAL_PIXEL_FORMAT_RGB_888: return fourcc('B', 'G', 'R', '3');
        case HAL_PIXEL_FORMAT_RGB_565: return fourcc('R', 'G', '1', '6');
        case HAL_PIXEL_FORMAT_BGRA_8888: return fourcc('A', 'R', '2', '4');
        case HAL_PIXEL_FORMAT_YCBCR_422_SP: return fourcc('N', 'V', '1', '6');
        case HAL_PIXEL_FORMAT_YCRCB_420_SP: return fourcc('N', 'V', '2', '1');
        case HAL_PIXEL_FORMAT_YCBCR_420_888: return fourcc('Y', 'U', '1', '2');
        case HAL_PIXEL_FORMAT_YV12: return fourcc('Y', 'V', '1', '2');
        case HAL_PIXEL_FORMAT_Y8: return fourcc('R', '8', ' ', ' ');
        case HAL_PIXEL_FORMAT_Y16: return fourcc('R', '1', '6', ' ');
        case HAL_PIXEL_FORMAT_RAW16: return fourcc('R', 'G', '1', '6');
        default: return 0;
    }
}

uint64_t bytesPerPixel(int32_t format) {
    switch (format) {
        case HAL_PIXEL_FORMAT_RGB_565:
        case HAL_PIXEL_FORMAT_RAW16:
        case HAL_PIXEL_FORMAT_Y16: return 2;
        case HAL_PIXEL_FORMAT_RGBA_FP16: return 8;
        case HAL_PIXEL_FORMAT_RGB_888: return 3;
        case HAL_PIXEL_FORMAT_YCBCR_420_888:
        case HAL_PIXEL_FORMAT_YV12:
        case HAL_PIXEL_FORMAT_YCRCB_420_SP: return 2;  // conservative 4:2:0 allocation estimate
        default: return 4;
    }
}

bool isRgbForAfbc(int32_t format) {
    return format == HAL_PIXEL_FORMAT_RGBA_8888 ||
            format == HAL_PIXEL_FORMAT_RGBX_8888 ||
            format == HAL_PIXEL_FORMAT_RGB_888 ||
            format == HAL_PIXEL_FORMAT_RGB_565 ||
            format == HAL_PIXEL_FORMAT_BGRA_8888 ||
            format == HAL_PIXEL_FORMAT_RGBA_FP16 ||
            format == HAL_PIXEL_FORMAT_RGBA_1010102;
}

bool y2sDrmModifier(const native_handle_t* buffer, int32_t format,
                    uint64_t* modifier) {
    if (!buffer || !modifier || buffer->version != 12 || buffer->numFds < 0 ||
        buffer->numInts < 0 || static_cast<size_t>(buffer->numFds) +
        static_cast<size_t>(buffer->numInts) != 65) return false;
    const size_t handleBytes = offsetof(native_handle_t, data) +
            static_cast<size_t>(buffer->numFds + buffer->numInts) * sizeof(int);
    if (exynos990::graphics::PrivateHandleLayout::kInternalFormat + sizeof(uint64_t) >
        handleBytes) return false;
    uint32_t magic = 0;
    std::memcpy(&magic, reinterpret_cast<const uint8_t*>(buffer) + 0x20, sizeof(magic));
    if (magic != 0x03141592U) return false;
    uint64_t internal = 0;
    std::memcpy(&internal, reinterpret_cast<const uint8_t*>(buffer) +
                        exynos990::graphics::PrivateHandleLayout::kInternalFormat,
                sizeof(internal));
    // The high word is an observed usage/format extension on GPU-linear
    // handles (for example 0x0000000100000001). It is safe to ignore only
    // when the packed low32 value has no modifier bits. Never truncate a
    // non-linear value with an unknown high word.
    const uint32_t packed = static_cast<uint32_t>(internal);
    if ((packed & ~exynos990::kY2sInternalBaseMask) == 0) {
        *modifier = 0;
        return true;
    }
    if ((internal >> 32) != 0) return false;
    return exynos990::decodeY2sDrmModifier(packed, isRgbForAfbc(format), modifier);
}

int32_t copyEncoded(const void* source, size_t sourceSize, void* output, size_t outputSize) {
    if (sourceSize > static_cast<size_t>(INT32_MAX)) return -AIMAPPER_ERROR_NO_RESOURCES;
    if (output && outputSize) {
        const size_t copied = std::min(sourceSize, outputSize);
        std::memcpy(output, source, copied);
    }
    return static_cast<int32_t>(sourceSize);
}

bool decodeMetadataHeader(int64_t type, const void* data, size_t size,
                          const uint8_t** payload, size_t* payloadSize) {
    if (!data || !payload || !payloadSize || size < sizeof(int64_t)) return false;
    const auto* bytes = static_cast<const uint8_t*>(data);
    size_t offset = 0;
    int64_t nameSize = 0;
    std::memcpy(&nameSize, bytes + offset, sizeof(nameSize));
    offset += sizeof(nameSize);
    if (nameSize < 0 || static_cast<size_t>(nameSize) != exynos990::metadata::kStandardName.size() ||
        size - offset < static_cast<size_t>(nameSize) + sizeof(int64_t) ||
        std::memcmp(bytes + offset, exynos990::metadata::kStandardName.data(), nameSize) != 0) {
        return false;
    }
    offset += static_cast<size_t>(nameSize);
    int64_t encodedType = 0;
    std::memcpy(&encodedType, bytes + offset, sizeof(encodedType));
    offset += sizeof(encodedType);
    if (encodedType != type) return false;
    *payload = bytes + offset;
    *payloadSize = size - offset;
    return true;
}

// Alguns formatos internos do Mali não têm uma representação pública no
// handle. Nesses casos, use a mesma rotina flexível que a câmera legada usa e
// traduza somente a geometria retornada por ela. Esse caminho é um fallback:
// os formatos NV12/NV21/YV12 mais comuns continuam sem lock para que uma
// consulta de metadata não toque em um buffer que ainda pertence ao produtor.
int32_t writeDriverFlexPlaneLayouts(buffer_handle_t buffer, int64_t type, uint32_t width,
                                    uint32_t height, void* output, size_t size) {
    uint32_t planeCount = 0;
    if (bridge().getNumFlexPlanes(bridge().device, buffer, &planeCount) != GRALLOC1_ERROR_NONE ||
        planeCount == 0 || planeCount > 8) {
        return -AIMAPPER_ERROR_UNSUPPORTED;
    }
    std::vector<android_flex_plane_t> planes(planeCount);
    android_flex_layout_t layout{
            .format = FLEX_FORMAT_INVALID,
            .num_planes = planeCount,
            .planes = planes.data(),
    };
    gralloc1_rect_t region{
            .left = 0,
            .top = 0,
            .width = static_cast<int32_t>(width),
            .height = static_cast<int32_t>(height),
    };
    if (bridge().lockFlex(bridge().device, buffer, 0,
                          GRALLOC1_CONSUMER_USAGE_CPU_READ, &region, &layout, -1) !=
        GRALLOC1_ERROR_NONE) {
        return -AIMAPPER_ERROR_UNSUPPORTED;
    }

    // lock() devolve o ponteiro da plane Y, e o Gralloc5 soma offsetInBytes a
    // ele. Os offsets precisam ser relativos ao Y, não ao menor endereço: em
    // alocações multi-FD (0x105) o Mali pode mapear o croma abaixo do Y, e o
    // offset relativo ao mínimo fazia o cliente escrever fora do mapeamento.
    // offsetInBytes é int64; um croma abaixo do Y gera um offset negativo.
    uintptr_t base = 0;
    bool valid = layout.num_planes > 0 && layout.num_planes <= planeCount;
    for (uint32_t index = 0; valid && index < layout.num_planes; ++index) {
        const android_flex_plane_t& plane = layout.planes[index];
        valid = plane.top_left && plane.bits_per_component > 0 && plane.bits_used > 0 &&
                plane.bits_used <= plane.bits_per_component && plane.h_increment != 0 &&
                plane.v_increment != 0 && plane.h_subsampling > 0 &&
                plane.v_subsampling > 0;
        if (valid && plane.component == FLEX_COMPONENT_Y)
            base = reinterpret_cast<uintptr_t>(plane.top_left);
    }
    if (!valid || base == 0) {
        int ignoredFence = -1;
        bridge().unlock(bridge().device, buffer, &ignoredFence);
        if (ignoredFence >= 0) close(ignoredFence);
        return -AIMAPPER_ERROR_BAD_BUFFER;
    }

    Writer writer(output, size);
    writer.header(type);
    writer.scalar<int64_t>(layout.num_planes);
    for (uint32_t index = 0; index < layout.num_planes; ++index) {
        const android_flex_plane_t& plane = layout.planes[index];
        const int64_t offset = static_cast<int64_t>(
                reinterpret_cast<uintptr_t>(plane.top_left) - base);
        // The Exynos flex callback reports h/v_subsampling for the backing
        // allocation, and on this vendor stack it also reports 2x2 for the
        // luma plane of some YUV buffers.  That value is not the public
        // component geometry: luma is always width x height.  Only chroma
        // components are subsampled when translating the fallback layout.
        const bool chroma = plane.component == FLEX_COMPONENT_Cb ||
                plane.component == FLEX_COMPONENT_Cr;
        const uint64_t hSubsampling = chroma ? plane.h_subsampling : 1;
        const uint64_t vSubsampling = chroma ? plane.v_subsampling : 1;
        const uint64_t planeWidth =
                (static_cast<uint64_t>(width) + hSubsampling - 1) / hSubsampling;
        const uint64_t planeHeight =
                (static_cast<uint64_t>(height) + vSubsampling - 1) / vSubsampling;
        const uint64_t rowStride = static_cast<uint64_t>(
                plane.v_increment < 0 ? -static_cast<int64_t>(plane.v_increment)
                                      : plane.v_increment);
        if (rowStride == 0 || planeWidth == 0 || planeHeight == 0) {
            int ignoredFence = -1;
            bridge().unlock(bridge().device, buffer, &ignoredFence);
            if (ignoredFence >= 0) close(ignoredFence);
            return -AIMAPPER_ERROR_BAD_BUFFER;
        }
        writer.scalar<int64_t>(1);
        writer.string(kPlaneComponentName);
        writer.scalar<int64_t>(plane.component);
        writer.scalar<int64_t>(0);
        writer.scalar<int64_t>(plane.bits_used);
        writer.scalar<int64_t>(offset);
        writer.scalar<int64_t>(static_cast<uint64_t>(
                plane.h_increment < 0 ? -static_cast<int64_t>(plane.h_increment)
                                       : plane.h_increment) * 8);
        writer.scalar<int64_t>(rowStride);
        writer.scalar<int64_t>(planeWidth);
        writer.scalar<int64_t>(planeHeight);
        writer.scalar<int64_t>(rowStride * planeHeight);
        writer.scalar<int64_t>(hSubsampling);
        writer.scalar<int64_t>(vSubsampling);
    }
    int ignoredFence = -1;
    const int32_t unlockError = bridge().unlock(bridge().device, buffer, &ignoredFence);
    if (ignoredFence >= 0) close(ignoredFence);
    if (unlockError != GRALLOC1_ERROR_NONE) return -AIMAPPER_ERROR_BAD_BUFFER;
    return writer.size();
}

int32_t writePlaneLayouts(buffer_handle_t buffer, int64_t type, void* output, size_t size) {
    uint32_t width = 0, height = 0, stride = 0;
    int32_t format = 0;
    if (bridge().getDimensions(bridge().device, buffer, &width, &height) ||
        bridge().getStride(bridge().device, buffer, &stride) ||
        bridge().getFormat(bridge().device, buffer, &format)) {
        return -AIMAPPER_ERROR_BAD_BUFFER;
    }

    // The S26+ Stable-C mapper publishes PlaneLayout for every SGR camera
    // allocation because its handle carries a public plane/FD table.  The
    // Exynos 990 camera format 0x11d is different: the stock Mali callback
    // exposes Y and UV through separate virtual mappings and the native
    // handle does not contain a cross-process FD index/layout description.
    // Returning a fabricated one-plane layout here makes GraphicBufferMapper
    // treat the private YUV handle as linear RGB/YUV and is the direct cause
    // of the green/black preview seen when the AIDL mapper is made global.
    // Keep the private handle on the original camera/HWC path until the
    // driver proves a Stable-C representation; AIDL callers can then fall
    // back instead of consuming a false layout.
    if (exynos990::graphics::isExynosPrivateCameraYuv(format)) {
        // Camera3 queries PlaneLayouts while the producer is streaming.  The
        // private 0x11d handle has no transportable Stable-C offsets, so the
        // answer remains UNSUPPORTED, but do not emit one log record for every
        // retry.  The old spam was enough to contend with the camera/HWC
        // threads and made the last preview buffer appear to loop.
        static std::atomic_bool camera_plane_layout_logged{false};
        if (!camera_plane_layout_logged.exchange(true)) {
            ALOGI("PlaneLayouts unsupported for private Exynos camera format 0x%x", format);
        }
        return -AIMAPPER_ERROR_UNSUPPORTED;
    }

    Writer writer(output, size);
    writer.header(type);
    auto plane = [&writer](int64_t component, uint64_t offset, uint64_t sampleBits,
                           uint64_t rowStride, uint64_t planeWidth, uint64_t planeHeight,
                           uint64_t horizontalSubsampling, uint64_t verticalSubsampling) {
        writer.scalar<int64_t>(1);
        writer.string(kPlaneComponentName);
        writer.scalar<int64_t>(component);
        writer.scalar<int64_t>(0);
        writer.scalar<int64_t>(8);
        writer.scalar<int64_t>(offset);
        writer.scalar<int64_t>(sampleBits);
        writer.scalar<int64_t>(rowStride);
        writer.scalar<int64_t>(planeWidth);
        writer.scalar<int64_t>(planeHeight);
        writer.scalar<int64_t>(rowStride * planeHeight);
        writer.scalar<int64_t>(horizontalSubsampling);
        writer.scalar<int64_t>(verticalSubsampling);
    };
    const uint64_t chromaWidth = (static_cast<uint64_t>(width) + 1) / 2;
    const uint64_t chromaHeight = (static_cast<uint64_t>(height) + 1) / 2;

    if (isImplementationDefinedCameraYuv(buffer, format)) {
        // lock() entrega o scratch linear de lockCameraPrivateYuv(): Y com o
        // stride do handle e, logo depois, o croma NV21 intercalado (Cr, Cb).
        // Sem isto o Gralloc5 recebia um plano RAW e devolvia android_ycbcr
        // zerado ao Motion Photo (memcpy em endereço nulo no app).
        uint32_t yStride = 0, chromaStride = 0;
        if (!readCameraYuvStrides(buffer, &yStride, &chromaStride))
            return -AIMAPPER_ERROR_UNSUPPORTED;
        const uint64_t chromaOffset = static_cast<uint64_t>(yStride) * height;
        writer.scalar<int64_t>(3);
        plane(FLEX_COMPONENT_Y, 0, 8, yStride, width, height, 1, 1);
        plane(FLEX_COMPONENT_Cb, chromaOffset + 1, 16, chromaStride, chromaWidth, chromaHeight,
              2, 2);
        plane(FLEX_COMPONENT_Cr, chromaOffset, 16, chromaStride, chromaWidth, chromaHeight,
              2, 2);
        return writer.size();
    }

    const bool flexibleYuv = format == HAL_PIXEL_FORMAT_YCBCR_420_888 ||
            format == HAL_PIXEL_FORMAT_YV12 || format == HAL_PIXEL_FORMAT_YCRCB_420_SP ||
            format == HAL_PIXEL_FORMAT_YCBCR_422_SP;
    if (flexibleYuv) {
        // The stock Exynos gralloc keeps the selected allocation YUV format and
        // its plane geometry in the native handle. Reading these immutable
        // fields avoids locking a producer-owned buffer merely to answer a
        // metadata query. The offsets match the private_handle_t consumed by
        // mali_gralloc_lock_ycbcr() in this exact Exynos 990 vendor stack.
        uint32_t allocationFormat = 0, yStride = 0, chromaOffset = 0;
        uint32_t chromaStride = 0, secondChromaOffset = 0;
        if (!readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kFormat,
                           &allocationFormat) ||
            !readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kYStride,
                           &yStride) ||
            !readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kChromaOffset,
                           &chromaOffset) ||
            !readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kChromaStride,
                           &chromaStride) ||
            yStride == 0 ||
            chromaStride == 0) {
            return writeDriverFlexPlaneLayouts(buffer, type, width, height, output, size);
        }
        if (allocationFormat != exynos990::graphics::kExynosNv12 &&
            allocationFormat != exynos990::graphics::kExynosNv21 &&
            allocationFormat != exynos990::graphics::kYv12) {
            ALOGI("Using driver flex layout for Exynos YUV allocation format 0x%x",
                  allocationFormat);
            return writeDriverFlexPlaneLayouts(buffer, type, width, height, output, size);
        }

        // YV12 has two independent chroma planes.  The optional second
        // offset is required only for that format; NV12/NV21 use one
        // interleaved plane and must not be rejected when the field is absent.
        if (allocationFormat == exynos990::graphics::kYv12 &&
            !readHandleU32(buffer, exynos990::graphics::PrivateHandleLayout::kSecondChromaOffset,
                           &secondChromaOffset)) {
            return writeDriverFlexPlaneLayouts(buffer, type, width, height, output, size);
        }

        writer.scalar<int64_t>(3);
        plane(FLEX_COMPONENT_Y, 0, 8, yStride, width, height, 1, 1);
        if (allocationFormat == exynos990::graphics::kYv12) {
            // YV12 stores Cr before Cb. The private handle publishes both
            // plane offsets, so padding/alignment stays vendor-accurate.
            plane(FLEX_COMPONENT_Cb, secondChromaOffset, 8, chromaStride,
                  chromaWidth, chromaHeight, 2, 2);
            plane(FLEX_COMPONENT_Cr, chromaOffset, 8, chromaStride,
                  chromaWidth, chromaHeight, 2, 2);
        } else {
            // Exynos 0x200 is NV12 (CbCr); 0x201 is NV21 (CrCb).
            const uint64_t cbOffset = chromaOffset +
                    (allocationFormat == exynos990::graphics::kExynosNv21 ? 1 : 0);
            const uint64_t crOffset = chromaOffset +
                    (allocationFormat == exynos990::graphics::kExynosNv12 ? 1 : 0);
            plane(FLEX_COMPONENT_Cb, cbOffset, 16, chromaStride,
                  chromaWidth, chromaHeight, 2, 2);
            plane(FLEX_COMPONENT_Cr, crOffset, 16, chromaStride,
                  chromaWidth, chromaHeight, 2, 2);
        }
        return writer.size();
    }

    const uint64_t bpp = bytesPerPixel(format);
    const uint64_t sampleBits = bpp * 8;
    const uint64_t strideBytes = static_cast<uint64_t>(stride) * bpp;
    writer.scalar<int64_t>(1);  // one linear plane
    const bool rgba = format == HAL_PIXEL_FORMAT_RGBA_8888 ||
                      format == HAL_PIXEL_FORMAT_RGBX_8888 ||
                      format == HAL_PIXEL_FORMAT_BGRA_8888;
    const int64_t componentCount = rgba ? 4 : 1;
    writer.scalar<int64_t>(componentCount);
    if (rgba) {
        constexpr int64_t components[] = {1 << 10, 1 << 11, 1 << 12, 1LL << 30};
        constexpr int64_t offsets[] = {0, 8, 16, 24};
        for (size_t index = 0; index < 4; ++index) {
            writer.string(kPlaneComponentName);
            writer.scalar<int64_t>(components[index]);
            writer.scalar<int64_t>(offsets[index]);
            writer.scalar<int64_t>(8);
        }
    } else {
        writer.string(kPlaneComponentName);
        writer.scalar<int64_t>(1 << 20);  // RAW, for formats without a flex description
        writer.scalar<int64_t>(0);
        writer.scalar<int64_t>(sampleBits);
    }
    writer.scalar<int64_t>(0);  // offsetInBytes
    writer.scalar<int64_t>(static_cast<int64_t>(sampleBits));
    writer.scalar<int64_t>(static_cast<int64_t>(strideBytes));
    writer.scalar<int64_t>(width);
    writer.scalar<int64_t>(height);
    writer.scalar<int64_t>(strideBytes * height);
    writer.scalar<int64_t>(1);
    writer.scalar<int64_t>(1);
    return writer.size();
}

int32_t writeCrop(buffer_handle_t buffer, int64_t type, void* output, size_t size) {
    uint32_t width = 0, height = 0;
    if (bridge().getDimensions(bridge().device, buffer, &width, &height))
        return -AIMAPPER_ERROR_BAD_BUFFER;
    Writer writer(output, size);
    writer.header(type);
    writer.scalar<int64_t>(1);
    writer.scalar<int32_t>(0);
    writer.scalar<int32_t>(0);
    writer.scalar<int32_t>(static_cast<int32_t>(width));
    writer.scalar<int32_t>(static_cast<int32_t>(height));
    return writer.size();
}

int32_t writeDefaultExtendable(int64_t type, const char* name, void* output, size_t size) {
    Writer writer(output, size);
    return writer.standardExtendable(type, name, 0);
}

int32_t getStandardMetadata(buffer_handle_t buffer, int64_t type, void* output, size_t size) {
    if (!isImported(buffer) || !bridge().ready) return -AIMAPPER_ERROR_BAD_BUFFER;
    std::vector<uint8_t> stored;
    if (importedBuffers().getMetadata(buffer, type, &stored))
        return copyEncoded(stored.data(), stored.size(), output, size);
    Writer writer(output, size);
    uint64_t u64 = 0;
    uint32_t width = 0, height = 0, layers = 0, stride = 0;
    int32_t format = 0;
    switch (type) {
        case 1:  // BUFFER_ID
            if (bridge().backingStore(bridge().device, buffer, &u64)) break;
            return writer.standard<uint64_t>(type, u64);
        case 2: {  // NAME: derive a stable diagnostic name from the allocation id
            uint64_t backingStore = 0;
            if (bridge().backingStore(bridge().device, buffer, &backingStore) ||
                backingStore == 0) {
                return writer.standardString(type, "exynos990-buffer");
            }
            char name[64] = {};
            const int length = std::snprintf(name, sizeof(name), "exynos990-buffer-%016llx",
                                             static_cast<unsigned long long>(backingStore));
            if (length <= 0 || static_cast<size_t>(length) >= sizeof(name))
                return -AIMAPPER_ERROR_NO_RESOURCES;
            return writer.standardString(type, std::string_view(name, static_cast<size_t>(length)));
        }
        case 3:  // WIDTH
        case 4:  // HEIGHT
            if (bridge().getDimensions(bridge().device, buffer, &width, &height)) break;
            return writer.standard<uint64_t>(type, type == 3 ? width : height);
        case 5:  // LAYER_COUNT
            if (bridge().getLayerCount(bridge().device, buffer, &layers)) break;
            return writer.standard<uint64_t>(type, layers);
        case 6:  // PIXEL_FORMAT_REQUESTED
            if (bridge().getFormat(bridge().device, buffer, &format)) break;
            return writer.standard<int32_t>(type, format);
        case 7:  // PIXEL_FORMAT_FOURCC
            if (bridge().getFormat(bridge().device, buffer, &format)) break;
            return writer.standard<uint32_t>(type, pixelFormatFourcc(format));
        case 8:  // PIXEL_FORMAT_MODIFIER
            if (bridge().getFormat(bridge().device, buffer, &format)) break;
            {
                uint64_t modifier = 0;
                if (!y2sDrmModifier(buffer, format, &modifier)) {
                    ALOGE("No verified y2s DRM modifier for handle=%p format=0x%x", buffer,
                          format);
                    return -AIMAPPER_ERROR_UNSUPPORTED;
                }
                return writer.standard<uint64_t>(type, modifier);
            }
        case 9: {  // USAGE
            uint64_t producer = 0, consumer = 0;
            if (bridge().getProducerUsage(bridge().device, buffer, &producer) ||
                bridge().getConsumerUsage(bridge().device, buffer, &consumer)) break;
            return writer.standard<uint64_t>(type,
                                             exynos990::graphics::toAidlUsage(producer, consumer));
        }
        case 10: {  // ALLOCATION_SIZE
            if (bridge().getDimensions(bridge().device, buffer, &width, &height) ||
                bridge().getStride(bridge().device, buffer, &stride) ||
                bridge().getFormat(bridge().device, buffer, &format) ||
                bridge().getLayerCount(bridge().device, buffer, &layers)) break;
            const uint64_t bpp = bytesPerPixel(format);
            const uint64_t rowBytes = static_cast<uint64_t>(stride) * bpp;
            if (height != 0 && rowBytes > UINT64_MAX / height) return -AIMAPPER_ERROR_NO_RESOURCES;
            const uint64_t imageBytes = rowBytes * height;
            if (layers != 0 && imageBytes > UINT64_MAX / layers)
                return -AIMAPPER_ERROR_NO_RESOURCES;
            return writer.standard<uint64_t>(type, imageBytes * layers);
        }
        case 11: {  // PROTECTED_CONTENT
            uint64_t producer = 0;
            if (bridge().getProducerUsage(bridge().device, buffer, &producer)) break;
            return writer.standard<uint64_t>(
                    type, (producer & GRALLOC1_PRODUCER_USAGE_PROTECTED) ? 1 : 0);
        }
        case 12:  // COMPRESSION
            return writeDefaultExtendable(type, kCompressionName, output, size);
        case 13:  // INTERLACED
            return writeDefaultExtendable(type, kInterlacedName, output, size);
        case 14:  // CHROMA_SITING
            return writeDefaultExtendable(type, kChromaSitingName, output, size);
        case 15:  // PLANE_LAYOUTS
            return writePlaneLayouts(buffer, type, output, size);
        case 16:  // CROP
            return writeCrop(buffer, type, output, size);
        case 17:  // DATASPACE
            return writer.standard<int32_t>(type, HAL_DATASPACE_UNKNOWN);
        case 18:  // BLEND_MODE
            return writer.standard<int32_t>(type, 0);  // INVALID
        case 19:  // SMPTE2086: optional until a producer supplies HDR metadata.
        case 20:  // CTA861_3: optional until a producer supplies HDR metadata.
            return 0;
        case 21:  // SMPTE2094_40: cached as opaque dynamic HDR metadata.
        case 22:  // SMPTE2094_10: cached as opaque dynamic HDR metadata.
            return 0;
        case 23:  // STRIDE
            if (bridge().getStride(bridge().device, buffer, &stride)) break;
            return writer.standard<uint64_t>(type, stride);
        default: return -AIMAPPER_ERROR_UNSUPPORTED;
    }
    return -AIMAPPER_ERROR_BAD_BUFFER;
}

int32_t getMetadata(buffer_handle_t buffer, AIMapper_MetadataType type, void* output, size_t size) {
    if (!type.name || std::string_view(type.name) != exynos990::metadata::kStandardName)
        return -AIMAPPER_ERROR_UNSUPPORTED;
    return getStandardMetadata(buffer, type.value, output, size);
}

bool isMutableMetadata(int64_t type) {
    return type == 17 || type == 18 || type == 19 || type == 20 ||
           type == 21 || type == 22;
}

AIMapper_Error setStandardMetadata(buffer_handle_t buffer, int64_t type, const void* data,
                                   size_t size) {
    if (!isImported(buffer) || !bridge().ready) return AIMAPPER_ERROR_BAD_BUFFER;
    if (!isMutableMetadata(type)) {
        return AIMAPPER_ERROR_BAD_VALUE;
    }
    if ((type == 19 || type == 20) && size == 0) {
        return importedBuffers().clearMetadata(buffer, type) ? AIMAPPER_ERROR_NONE
                                                              : AIMAPPER_ERROR_BAD_BUFFER;
    }
    const uint8_t* payload = nullptr;
    size_t payloadSize = 0;
    if (!decodeMetadataHeader(type, data, size, &payload, &payloadSize))
        return AIMAPPER_ERROR_BAD_VALUE;
    if ((type == 17 || type == 18) && payloadSize != sizeof(int32_t))
        return AIMAPPER_ERROR_BAD_VALUE;
    if (type == 19 && payloadSize != 40) return AIMAPPER_ERROR_BAD_VALUE;
    if (type == 20 && payloadSize != 8) return AIMAPPER_ERROR_BAD_VALUE;
    // Dynamic HDR metadata is an opaque byte vector. Keep a bounded copy in
    // the per-process metadata cache; the legacy driver has no field for it.
    if ((type == 21 || type == 22) && (payloadSize == 0 || payloadSize > 64 * 1024))
        return AIMAPPER_ERROR_BAD_VALUE;
    return importedBuffers().setMetadata(buffer, type, data, size)
            ? AIMAPPER_ERROR_NONE
            : AIMAPPER_ERROR_BAD_BUFFER;
}

AIMapper_Error setMetadata(buffer_handle_t buffer, AIMapper_MetadataType type, const void* data,
                           size_t size) {
    if (!type.name || std::string_view(type.name) != exynos990::metadata::kStandardName)
        return AIMAPPER_ERROR_UNSUPPORTED;
    return setStandardMetadata(buffer, type.value, data, size);
}

const AIMapper_MetadataTypeDescription* metadataDescriptions(size_t* count) {
    static const AIMapper_MetadataTypeDescription descriptions[] = {
            {{exynos990::metadata::kStandardName.data(), 1}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 2}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 3}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 4}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 5}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 6}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 7}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 8}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 9}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 10}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 11}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 12}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 13}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 14}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 15}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 16}, nullptr, true, false, {}},
            {{exynos990::metadata::kStandardName.data(), 17}, nullptr, true, true, {}},
            {{exynos990::metadata::kStandardName.data(), 18}, nullptr, true, true, {}},
            {{exynos990::metadata::kStandardName.data(), 19}, nullptr, true, true, {}},
            {{exynos990::metadata::kStandardName.data(), 20}, nullptr, true, true, {}},
            {{exynos990::metadata::kStandardName.data(), 21}, nullptr, true, true, {}},
            {{exynos990::metadata::kStandardName.data(), 22}, nullptr, true, true, {}},
            {{exynos990::metadata::kStandardName.data(), 23}, nullptr, true, false, {}},
    };
    if (count) *count = sizeof(descriptions) / sizeof(descriptions[0]);
    return descriptions;
}

AIMapper_Error listMetadata(const AIMapper_MetadataTypeDescription** list, size_t* count) {
    if (!list || !count) return AIMAPPER_ERROR_BAD_VALUE;
    *list = metadataDescriptions(count);
    return AIMAPPER_ERROR_NONE;
}

AIMapper_Error dumpBuffer(buffer_handle_t buffer, AIMapper_DumpBufferCallback callback, void* context) {
    if (!isImported(buffer) || !callback) return AIMAPPER_ERROR_BAD_BUFFER;
    size_t count = 0;
    const auto* descriptions = metadataDescriptions(&count);
    std::vector<uint8_t> value;
    for (size_t index = 0; index < count; ++index) {
        if (!descriptions[index].isGettable) continue;
        const auto type = descriptions[index].metadataType;
        const int32_t required = getStandardMetadata(buffer, type.value, nullptr, 0);
        if (required < 0 || required == 0) continue;
        value.resize(static_cast<size_t>(required));
        if (getStandardMetadata(buffer, type.value, value.data(), value.size()) != required)
            return AIMAPPER_ERROR_NO_RESOURCES;
        callback(context, type, value.data(), value.size());
    }
    return AIMAPPER_ERROR_NONE;
}

AIMapper_Error dumpAll(AIMapper_BeginDumpBufferCallback begin, AIMapper_DumpBufferCallback callback,
                       void* context) {
    if (!begin || !callback) return AIMAPPER_ERROR_BAD_VALUE;
    std::vector<buffer_handle_t> buffers;
    importedBuffers().snapshot(&buffers);
    for (buffer_handle_t buffer : buffers) {
        begin(context);
        const AIMapper_Error error = dumpBuffer(buffer, callback, context);
        if (error != AIMAPPER_ERROR_NONE) return error;
    }
    return AIMAPPER_ERROR_NONE;
}

AIMapper_Error getReservedRegion(buffer_handle_t buffer, void** address, uint64_t* size) {
    if (!address || !size) return AIMAPPER_ERROR_BAD_VALUE;
    if (!isImported(buffer)) return AIMAPPER_ERROR_BAD_BUFFER;
    *address = nullptr;
    *size = 0;
    return AIMAPPER_ERROR_NONE;
}

// The proprietary Camera3 blob is linked against the old
// GrallocMapperCamera C++ ABI.  Keep that ABI in a tiny facade, but place the
// actual camera lock state in this Stable-C mapper.  This is intentionally
// separate from AIMapper::lock(): Camera3 passes a combined legacy usage mask
// and requires three YCbCr plane pointers, while Stable-C lock accepts CPU
// usage and returns one address.  Translating either contract would corrupt
// the private 0x11d layout.
template <typename NullCall, typename ModuleCall>
int callLegacyCameraHelper(const char* name, NullCall&& nullCall, ModuleCall&& moduleCall) {
    const int result = nullCall();
    if (result == GRALLOC1_ERROR_NONE || !bridge().cameraModule) return result;
    const int fallback = moduleCall();
    static std::atomic_bool logged{false};
    if (!logged.exchange(true)) {
        ALOGI("Camera AIDL core %s: null context=%d, module context=%d", name, result,
              fallback);
    }
    return fallback;
}

extern "C" __attribute__((visibility("default"))) int exynos990_aidl_camera_lock(
        const native_handle_t* buffer, uint64_t usage, const exynos990_camera_rect_t* rect,
        int fence, void** output) {
    if (!bridge().cameraReady || !bridge().cameraLockAsync || !buffer || !rect || !output)
        return GRALLOC1_ERROR_BAD_HANDLE;
    return callLegacyCameraHelper(
            "lock_async",
            [&] { return bridge().cameraLockAsync(nullptr, buffer, usage, rect->left, rect->top,
                                                   rect->width, rect->height, output, fence); },
            [&] { return bridge().cameraLockAsync(bridge().cameraModule, buffer, usage,
                                                   rect->left, rect->top, rect->width, rect->height,
                                                   output, fence); });
}

extern "C" __attribute__((visibility("default"))) int exynos990_aidl_camera_lock_ycbcr(
        const native_handle_t* buffer, uint64_t usage, const exynos990_camera_rect_t* rect,
        int fence, exynos990_camera_ycbcr_t* output) {
    if (!bridge().cameraReady || !bridge().cameraGetNumFlexPlanes ||
        !bridge().cameraLockFlexAsync || !bridge().cameraUnlock || !buffer || !rect || !output) {
        return GRALLOC1_ERROR_BAD_HANDLE;
    }
    uint32_t planeCount = 0;
    const int planeError = callLegacyCameraHelper(
            "get_num_flex_planes",
            [&] { return bridge().cameraGetNumFlexPlanes(nullptr, buffer, &planeCount); },
            [&] { return bridge().cameraGetNumFlexPlanes(bridge().cameraModule, buffer,
                                                          &planeCount); });
    if (planeError != GRALLOC1_ERROR_NONE || planeCount == 0 || planeCount > 8) {
        return planeError != GRALLOC1_ERROR_NONE ? planeError : GRALLOC1_ERROR_BAD_VALUE;
    }

    android_flex_plane_t planes[8]{};
    android_flex_layout_t layout{
            .format = FLEX_FORMAT_INVALID,
            .num_planes = planeCount,
            .planes = planes,
    };
    const int error = callLegacyCameraHelper(
            "lock_flex_async",
            [&] { return bridge().cameraLockFlexAsync(nullptr, buffer, usage, rect->left,
                                                       rect->top, rect->width, rect->height,
                                                       &layout, fence); },
            [&] { return bridge().cameraLockFlexAsync(bridge().cameraModule, buffer, usage,
                                                       rect->left, rect->top, rect->width,
                                                       rect->height, &layout, fence); });
    if (error != GRALLOC1_ERROR_NONE) return error;

    const android_flex_plane_t* y = nullptr;
    const android_flex_plane_t* cb = nullptr;
    const android_flex_plane_t* cr = nullptr;
    for (uint32_t index = 0; index < layout.num_planes && index < 8; ++index) {
        const android_flex_plane_t& plane = layout.planes[index];
        if (!plane.top_left) continue;
        if (plane.component == FLEX_COMPONENT_Y) y = &plane;
        if (plane.component == FLEX_COMPONENT_Cb) cb = &plane;
        if (plane.component == FLEX_COMPONENT_Cr) cr = &plane;
    }
    if (!y || !cb || !cr) {
        (void)callLegacyCameraHelper(
                "unlock_invalid_layout",
                [&] { return bridge().cameraUnlock(nullptr, buffer); },
                [&] { return bridge().cameraUnlock(bridge().cameraModule, buffer); });
        return GRALLOC1_ERROR_UNSUPPORTED;
    }
    output->y = y->top_left;
    output->cb = cb->top_left;
    output->cr = cr->top_left;
    output->yStride = static_cast<uint32_t>(y->v_increment);
    output->cStride = static_cast<uint32_t>(cb->v_increment);
    output->chromaStep = static_cast<uint32_t>(cb->h_increment);
    return GRALLOC1_ERROR_NONE;
}

extern "C" __attribute__((visibility("default"))) int exynos990_aidl_camera_unlock(
        const native_handle_t* buffer) {
    if (!bridge().cameraReady || !bridge().cameraUnlock || !buffer)
        return GRALLOC1_ERROR_BAD_HANDLE;
    return callLegacyCameraHelper(
            "unlock", [&] { return bridge().cameraUnlock(nullptr, buffer); },
            [&] { return bridge().cameraUnlock(bridge().cameraModule, buffer); });
}

AIMapper gMapper = {
        .version = AIMAPPER_VERSION_5,
        .v5 = {
                .importBuffer = importBuffer,
                .freeBuffer = freeBuffer,
                .getTransportSize = getTransportSize,
                .lock = lockBuffer,
                .unlock = unlockBuffer,
                .flushLockedBuffer = [](buffer_handle_t buffer) {
                    return syncLockedBuffer(buffer, false);
                },
                .rereadLockedBuffer = [](buffer_handle_t buffer) {
                    return syncLockedBuffer(buffer, true);
                },
                .getMetadata = getMetadata,
                .getStandardMetadata = getStandardMetadata,
                .setMetadata = setMetadata,
                .setStandardMetadata = setStandardMetadata,
                .listSupportedMetadataTypes = listMetadata,
                .dumpBuffer = dumpBuffer,
                .dumpAllBuffers = dumpAll,
                .getReservedRegion = getReservedRegion,
        },
};

}  // namespace

extern "C" __attribute__((visibility("default"))) uint32_t ANDROID_HAL_STABLEC_VERSION =
        AIMAPPER_VERSION_5;

extern "C" __attribute__((visibility("default"))) AIMapper_Error AIMapper_loadIMapper(
        AIMapper** implementation) {
    if (!implementation || !bridge().ready) return AIMAPPER_ERROR_UNSUPPORTED;
    *implementation = &gMapper;
    return AIMAPPER_ERROR_NONE;
}

