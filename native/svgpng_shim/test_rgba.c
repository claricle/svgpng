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
    test_errors_leave_buffers_untouched();
    test_adjacent_buffers();
    puts("RGBA conversion assertions passed");
    return 0;
}
