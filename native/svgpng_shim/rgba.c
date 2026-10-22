#include "rgba.h"

#define SVGPNG_MAX_DIMENSION ((size_t)32768)
#define SVGPNG_MAX_PIXELS ((size_t)64000000)
#define SVGPNG_MAX_BUFFER ((size_t)268435456)

static uint8_t straight_channel(uint8_t channel, uint8_t alpha)
{
    uint32_t value;

    if (alpha == 0) {
        return 0;
    }
    /* uint32_t holds the maximum numerator: 255 * 255 + 255 / 2. */
    value = ((uint32_t)channel * 255 + alpha / 2) / alpha;
    return (uint8_t)(value > 255 ? 255 : value);
}

svgpng_v1_rgba_status svgpng_v1_rgba_to_straight(
    const uint8_t *source, size_t source_length, size_t source_stride,
    uint8_t *destination, size_t destination_length, size_t destination_stride,
    size_t width, size_t height)
{
    size_t row_bytes, pixels, source_bytes, destination_bytes;
    uintptr_t source_start, destination_start;
    size_t row, column;

    if (source == NULL || destination == NULL || width == 0 || height == 0) {
        return SVGPNG_V1_RGBA_INVALID_ARGUMENT;
    }
    if (width > SIZE_MAX / 4 || width > SIZE_MAX / height) {
        return SVGPNG_V1_RGBA_OVERFLOW;
    }
    row_bytes = width * 4;
    pixels = width * height;
    if (source_stride < row_bytes || destination_stride < row_bytes) {
        return SVGPNG_V1_RGBA_INVALID_ARGUMENT;
    }
    if (source_stride > SIZE_MAX / height || destination_stride > SIZE_MAX / height) {
        return SVGPNG_V1_RGBA_OVERFLOW;
    }
    source_bytes = source_stride * height;
    destination_bytes = destination_stride * height;
    if (width > SVGPNG_MAX_DIMENSION || height > SVGPNG_MAX_DIMENSION ||
        pixels > SVGPNG_MAX_PIXELS || source_bytes > SVGPNG_MAX_BUFFER ||
        destination_bytes > SVGPNG_MAX_BUFFER) {
        return SVGPNG_V1_RGBA_LIMIT_EXCEEDED;
    }
    if (source_length < source_bytes || destination_length < destination_bytes) {
        return SVGPNG_V1_RGBA_BUFFER_TOO_SMALL;
    }
    source_start = (uintptr_t)source;
    destination_start = (uintptr_t)destination;
    if (source_bytes > UINTPTR_MAX - source_start ||
        destination_bytes > UINTPTR_MAX - destination_start) {
        return SVGPNG_V1_RGBA_OVERFLOW;
    }
    if (source_start < destination_start + destination_bytes &&
        destination_start < source_start + source_bytes) {
        return SVGPNG_V1_RGBA_OVERLAPPING_BUFFERS;
    }

    for (row = 0; row < height; row++) {
        const uint8_t *input = source + row * source_stride;
        uint8_t *output = destination + row * destination_stride;
        for (column = 0; column < row_bytes; column += 4) {
            uint8_t alpha = input[column + 3];
            output[column] = straight_channel(input[column], alpha);
            output[column + 1] = straight_channel(input[column + 1], alpha);
            output[column + 2] = straight_channel(input[column + 2], alpha);
            output[column + 3] = alpha;
        }
    }
    return SVGPNG_V1_RGBA_OK;
}
