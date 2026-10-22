#ifndef SVGPNG_RGBA_H
#define SVGPNG_RGBA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum svgpng_v1_rgba_status {
    SVGPNG_V1_RGBA_OK = 0,
    SVGPNG_V1_RGBA_INVALID_ARGUMENT = 1,
    SVGPNG_V1_RGBA_OVERFLOW = 2,
    SVGPNG_V1_RGBA_LIMIT_EXCEEDED = 3,
    SVGPNG_V1_RGBA_BUFFER_TOO_SMALL = 4,
    SVGPNG_V1_RGBA_OVERLAPPING_BUFFERS = 5
} svgpng_v1_rgba_status;

/* Convert premultiplied RGBA8 to straight RGBA8, preserving alpha and row order.
 * Both buffers belong to the caller and must be disjoint. Strides are in bytes
 * and each capacity must cover stride * height, including final-row padding.
 * Padding and the source are untouched. Every error leaves the destination
 * untouched. This function allocates nothing and is not a renderer or encoder.
 */
svgpng_v1_rgba_status svgpng_v1_rgba_to_straight(
    const uint8_t *source, size_t source_length, size_t source_stride,
    uint8_t *destination, size_t destination_length, size_t destination_stride,
    size_t width, size_t height);

#ifdef __cplusplus
}
#endif

#endif
