// ARCE.AI — Vulkan 1.1 symbol shim (low-API-level Android devices)
//
// ggml-vulkan calls vkGetPhysicalDeviceFeatures2 (Vulkan 1.1). The NDK
// libvulkan.so only exports Vulkan 1.0 symbols for API < 28, so linking
// for android-26 fails. This shim defines the symbol locally:
//   * API 28+ devices: forwards to the real loader function (full Vulkan).
//   * API 26/27 devices: reports the Vulkan 1.0 feature set (1.1+ features
//     left disabled) so ggml-vulkan detects "Vulkan too old" and the app
//     falls back to the CPU backend gracefully.
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <cstring>

namespace {
using PFN_GetFeatures2 = void (*)(VkPhysicalDevice, VkPhysicalDeviceFeatures2*);

PFN_GetFeatures2 real_get_features2() {
    static PFN_GetFeatures2 fn = []() -> PFN_GetFeatures2 {
        const char* paths[] = {
            "/system/lib64/libvulkan.so",
            "/system/lib/libvulkan.so",
        };
        for (const char* p : paths) {
            void* h = dlopen(p, RTLD_NOW | RTLD_LOCAL);
            if (!h) continue;
            PFN_GetFeatures2 f = reinterpret_cast<PFN_GetFeatures2>(dlsym(h, "vkGetPhysicalDeviceFeatures2"));
            if (f) return f;
            dlclose(h);
        }
        return nullptr;
    }();
    return fn;
}
}  // namespace

extern "C" __attribute__((visibility("hidden"))) VKAPI_ATTR void VKAPI_CALL
vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,
                              VkPhysicalDeviceFeatures2* pFeatures) {
    PFN_GetFeatures2 real = real_get_features2();
    if (real) { real(physicalDevice, pFeatures); return; }
    // Vulkan 1.0-only loader: report the base feature set, 1.1+ disabled.
    std::memset(pFeatures, 0, sizeof(*pFeatures));
    pFeatures->sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    pFeatures->pNext = nullptr;
    VkPhysicalDeviceFeatures base{};
    vkGetPhysicalDeviceFeatures(physicalDevice, &base);
    pFeatures->features = base;
}
