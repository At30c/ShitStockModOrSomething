# Exynos 990 graphics driver reverse-engineering notes

## Captured binaries

The unmodified y2s vendor binaries used for this analysis are stored outside
the build module under `out/target/y2s/graphics-re/`.  They were read from the
running device after the original vendor image had been restored.

| Binary | SHA-256 |
| --- | --- |
| `android.hardware.graphics.mapper@2.0-impl-2.1.so` | `b80b5e191750144137eb1e85b761dd7b4cc144c5f42b04a74810c254f6d4e022` |
| `android.hardware.graphics.allocator@2.0-impl.so` | `ecad7a19c30e2c3bbd9f888f867486a00de758af1149b8f92dec83e52bda8d32` |
| `gralloc.exynos990.so` | `1dd0cd1c9d20b224f63f780bfc647f828203e3fb2b5654172aa6d86aed9b70e7` |
| `gralloc.default.so` | `9709ce588975888e8509aeb4af45315fe8009c6b1088be8b1e0c83e6986b76a8` |

## Ownership contract recovered from `gralloc.exynos990.so`

The 64-bit gralloc is an Android 30 ARM64 Gralloc1 module.  Its public symbols
and disassembly establish the following behavior:

- `getCapabilities()` reports one capability, value 2 (`LAYERED_BUFFERS`).
- `GRALLOC1_FUNCTION_IMPORT_BUFFER` clones the incoming `native_handle`, then
  calls `mali_gralloc_reference_retain()` on that clone.
- The first retain in a process records the importing PID, initializes the
  per-process reference count and imports/maps the Exynos ION handles.
- `GRALLOC1_FUNCTION_RELEASE` calls
  `mali_gralloc_reference_release(module, handle, true)`.
- The final release unmaps/frees the imported ION state and deletes the cloned
  handle.  A handle must consequently be released once and only once.

The stock Mapper 2.1 library is based on AOSP's passthrough implementation. It
keeps a process-wide `GrallocImportedBufferPool`, rejects foreign handles and
removes a handle from the pool before forwarding the final release.  The first
stable-C prototype forwarded handles directly and omitted this ownership
registry.  The reconstructed Mapper 5 implementation now mirrors that pool
behavior while continuing to use the original driver's import/release entry
points.

Reference sources:

- AOSP Gralloc1 API contract:
  <https://android.googlesource.com/platform/hardware/libhardware/+/refs/heads/android10-release/include/hardware/gralloc1.h>
- AOSP Mapper 2.1 passthrough:
  <https://android.googlesource.com/platform/hardware/interfaces/+/aedfe936ef5cdcf38cbcbac5bcf43f5a5363ddc5/graphics/mapper/2.1/utils/passthrough/include/mapper-passthrough/2.1/Gralloc1Hal.h>

## Safety status

The module remains disabled in normal builds.  The v5 image was installed on
y2s and passed a 10,000-cycle allocate/import/lock/unlock/free test, including
duplicate imports and double-free rejection.  During a Clash Royale run the
IOVMM counters stayed near baseline (about 25--31 net mappings, with roughly
2.8 GiB free), and no `vmm num_map` warning or mapper crash appeared.  This is
enough to validate the ownership fix, but longer gameplay and DMA-BUF
accounting are still required before enabling it in production.

## Native AIDL graphics stack direction

The running y2s stack and kernel source establish these boundaries:

| Layer | Current implementation | Direction |
| --- | --- | --- |
| Kernel GPU | Mali kbase Valhall r38p1, available as source in the kernel tree | Keep r38p1 initially; add diagnostics and fixes in source |
| GLES/OpenCL compiler | Proprietary `libGLES_mali.so` | Keep as a matched r38p1 userspace component |
| Vulkan ICD | Proprietary `vulkan.mali.so` over `libGLES_mali.so` | Keep with the matching Mali userspace DDK |
| Buffer backend | ARM/Samsung Gralloc1 in `gralloc.exynos990.so` | Reconstruct from the public ARM implementation and recovered Samsung ABI |
| Mapper | HIDL 2.1 AOSP passthrough | Replace with a native stable-C Mapper 5 built from source |
| Allocator | HIDL 2.0 service | Replace with a native AIDL allocator v2 built from source |
| Composer | Samsung HWC2 behind Composer HIDL 2.3 | Preserve HWC2 initially; evaluate an AIDL Composer frontend separately |

This split modernizes the Android-facing HAL without changing the command
stream compiler or the `native_handle` layout consumed by HWC, camera and
codecs.  A later Mali DDK update must treat kbase, `libGLES_mali.so`, Vulkan and
their UAPI as one matched set; changing the kernel driver by itself is not a
valid update.

The next image must therefore be built in two stages.  First, run the rebuilt
Mapper/Allocator against the stock r38p1 graphics backend while sampling
`/sys/kernel/debug/mali0/gpu_memory`, every per-context `mem_*` counter and the
DMA-BUF table.  Only after buffer ownership remains balanced under sustained
composition should the source-built gralloc replace the proprietary Gralloc1
module.
