#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// Simple high-performance native checksum for block validation
// In a full implementation, this would be SHA-256 or similar
uint32_t vaultsync_sum(const uint8_t* data, int32_t length) {
    uint32_t sum = 0;
    for (int32_t i = 0; i < length; i++) {
        sum += data[i];
    }
    return sum;
}

#ifdef __cplusplus
}
#endif
