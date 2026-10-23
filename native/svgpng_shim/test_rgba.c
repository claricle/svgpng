#include "rgba.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_pixels_and_rows(void)
{
    const uint8_t pixels[] = {
        255, 128, 1, 0, 1, 0, 2, 1, 1, 2, 0, 2,
        1, 2, 3, 3, 64, 1, 127, 128, 17, 128, 255, 255
    };
    const uint8_t expected[] = {
        0, 0, 0, 0, 255, 0, 255, 1, 128, 255, 0, 2,
        85, 170, 255, 3, 128, 2, 253, 128, 17, 128, 255, 255
    };
    uint8_t source[30], original[30], destination[34];

    memset(source, 0xa5, sizeof(source));
    memset(destination, 0xcc, sizeof(destination));
    memcpy(source + 1, pixels, 12);
    memcpy(source + 15, pixels + 12, 12);
    memcpy(original, source, sizeof(source));
    assert(svgpng_v1_rgba_to_straight(source + 1, 28, 14,
        destination + 1, 32, 16, 3, 2) == SVGPNG_V1_RGBA_OK);
    assert(memcmp(destination + 1, expected, 12) == 0);
    assert(memcmp(destination + 17, expected + 12, 12) == 0);
    assert(memcmp(source, original, sizeof(source)) == 0);
    assert(destination[0] == 0xcc && destination[33] == 0xcc);
    for (size_t i = 13; i < 17; i++) {
        assert(destination[i] == 0xcc);
        assert(destination[i + 16] == 0xcc);
    }
}

static void assert_nearest_channel(uint8_t channel, uint8_t alpha, uint8_t result)
{
    if (alpha == 0) {
        assert(result == 0);
    } else if (channel >= alpha) {
        assert(result == 255);
    } else {
        /* Reconstruct the premultiplied value: nearest rounding has at most
         * half an alpha unit of error, with exact ties rounded upward. This
         * characterizes the answer without repeating the conversion formula. */
        int32_t error = (int32_t)result * alpha - (int32_t)channel * 255;
        assert(-(int32_t)alpha < 2 * error);
        assert(2 * error <= (int32_t)alpha);
    }
}

static void test_all_channel_alpha_pairs(void)
{
    enum { ROW_BYTES = 256 * 4 };
    uint8_t source[ROW_BYTES + 2], original[ROW_BYTES + 2];
    uint8_t destination[ROW_BYTES + 2];

    for (unsigned int alpha = 0; alpha < 256; alpha++) {
        memset(source, 0xa5, sizeof(source));
        memset(destination, 0xcc, sizeof(destination));
        for (unsigned int channel = 0; channel < 256; channel++) {
            size_t offset = 1 + channel * 4;
            source[offset] = (uint8_t)channel;
            source[offset + 1] = (uint8_t)(255 - channel);
            /* Multiplication by an odd number permutes all byte values. */
            source[offset + 2] = (uint8_t)(channel * 73);
            source[offset + 3] = (uint8_t)alpha;
        }
        memcpy(original, source, sizeof(source));

        assert(svgpng_v1_rgba_to_straight(source + 1, ROW_BYTES, ROW_BYTES,
            destination + 1, ROW_BYTES, ROW_BYTES, 256, 1) == SVGPNG_V1_RGBA_OK);
        for (unsigned int channel = 0; channel < 256; channel++) {
            size_t offset = 1 + channel * 4;
            for (size_t component = 0; component < 3; component++) {
                assert_nearest_channel(source[offset + component],
                    (uint8_t)alpha, destination[offset + component]);
            }
            assert(destination[offset + 3] == alpha);
        }
        assert(memcmp(source, original, sizeof(source)) == 0);
        assert(destination[0] == 0xcc);
        assert(destination[ROW_BYTES + 1] == 0xcc);
    }
}

static void test_errors_leave_buffers_untouched(void)
{
    uint8_t source[34], destination[34], source_before[34], destination_before[34];
    memset(source, 0xa5, sizeof(source));
    memset(destination, 0xcc, sizeof(destination));
    memcpy(source_before, source, sizeof(source));
    memcpy(destination_before, destination, sizeof(destination));

#define EXPECT_ERROR(call, status) do { \
    assert((call) == (status)); \
    assert(memcmp(source, source_before, sizeof(source)) == 0); \
    assert(memcmp(destination, destination_before, sizeof(destination)) == 0); \
} while (0)
#define CONVERT(src, slen, ss, dst, dlen, ds, w, h) \
    svgpng_v1_rgba_to_straight(src, slen, ss, dst, dlen, ds, w, h)

    EXPECT_ERROR(CONVERT(NULL, 4, 4, destination, 4, 4, 1, 1), SVGPNG_V1_RGBA_INVALID_ARGUMENT);
    EXPECT_ERROR(CONVERT(source, 4, 4, NULL, 4, 4, 1, 1), SVGPNG_V1_RGBA_INVALID_ARGUMENT);
    EXPECT_ERROR(CONVERT(source, 4, 4, destination, 4, 4, 0, 1), SVGPNG_V1_RGBA_INVALID_ARGUMENT);
    EXPECT_ERROR(CONVERT(source, 4, 4, destination, 4, 4, 1, 0), SVGPNG_V1_RGBA_INVALID_ARGUMENT);
    EXPECT_ERROR(CONVERT(source, 4, 3, destination, 4, 4, 1, 1), SVGPNG_V1_RGBA_INVALID_ARGUMENT);
    EXPECT_ERROR(CONVERT(source, 4, 4, destination, 4, 3, 1, 1), SVGPNG_V1_RGBA_INVALID_ARGUMENT);
    EXPECT_ERROR(CONVERT(source, 3, 4, destination, 4, 4, 1, 1), SVGPNG_V1_RGBA_BUFFER_TOO_SMALL);
    EXPECT_ERROR(CONVERT(source, 4, 4, destination, 3, 4, 1, 1), SVGPNG_V1_RGBA_BUFFER_TOO_SMALL);
    EXPECT_ERROR(CONVERT(source, 11, 6, destination, 12, 6, 1, 2), SVGPNG_V1_RGBA_BUFFER_TOO_SMALL);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, SIZE_MAX, destination, SIZE_MAX, SIZE_MAX, SIZE_MAX, 1), SVGPNG_V1_RGBA_OVERFLOW);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, 4, destination, SIZE_MAX, 4, 2, SIZE_MAX), SVGPNG_V1_RGBA_OVERFLOW);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, SIZE_MAX, destination, 8, 4, 1, 2), SVGPNG_V1_RGBA_OVERFLOW);
    EXPECT_ERROR(CONVERT(source, 8, 4, destination, SIZE_MAX, SIZE_MAX, 1, 2), SVGPNG_V1_RGBA_OVERFLOW);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, 131076, destination, SIZE_MAX, 131076, 32769, 1), SVGPNG_V1_RGBA_LIMIT_EXCEEDED);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, 4, destination, SIZE_MAX, 4, 1, 32769), SVGPNG_V1_RGBA_LIMIT_EXCEEDED);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, 32004, destination, SIZE_MAX, 32004, 8001, 8000), SVGPNG_V1_RGBA_LIMIT_EXCEEDED);
    EXPECT_ERROR(CONVERT(source, SIZE_MAX, 268435457, destination, 4, 4, 1, 1), SVGPNG_V1_RGBA_LIMIT_EXCEEDED);
    EXPECT_ERROR(CONVERT(source, 4, 4, destination, SIZE_MAX, 268435457, 1, 1), SVGPNG_V1_RGBA_LIMIT_EXCEEDED);
    EXPECT_ERROR(CONVERT(source, 4, 4, source, 4, 4, 1, 1), SVGPNG_V1_RGBA_OVERLAPPING_BUFFERS);
    EXPECT_ERROR(CONVERT(source, 8, 8, source + 4, 8, 8, 1, 1), SVGPNG_V1_RGBA_OVERLAPPING_BUFFERS);
    EXPECT_ERROR(CONVERT(source + 4, 8, 8, source, 8, 8, 1, 1), SVGPNG_V1_RGBA_OVERLAPPING_BUFFERS);

#undef CONVERT
#undef EXPECT_ERROR
}

static void test_adjacent_buffers(void)
{
    uint8_t storage[] = { 1, 2, 3, 3, 0, 0, 0, 0 };
    const uint8_t expected[] = { 1, 2, 3, 3, 85, 170, 255, 3 };
    assert(svgpng_v1_rgba_to_straight(storage, 4, 4, storage + 4, 4, 4, 1, 1) == SVGPNG_V1_RGBA_OK);
    assert(memcmp(storage, expected, sizeof(storage)) == 0);
}

int main(void)
{
    test_pixels_and_rows();
    test_all_channel_alpha_pairs();
    test_errors_leave_buffers_untouched();
    test_adjacent_buffers();
    puts("RGBA conversion assertions passed");
    return 0;
}
