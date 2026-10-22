#include "encoder.h"

#include <assert.h>
#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#ifdef SVGPNG_ENCODER_FAULT_TEST
/* Include the implementation only in this separate test executable, so every
 * shim/libpng allocation can fail without adding production fault switches. */
static size_t allocation_attempts;
static size_t fail_at = SIZE_MAX;
static size_t outstanding_allocations;

static void *test_malloc(size_t bytes)
{
    void *pointer;
    if (allocation_attempts++ == fail_at) {
        return NULL;
    }
    pointer = malloc(bytes);
    if (pointer != NULL) {
        outstanding_allocations++;
    }
    return pointer;
}

static void *test_calloc(size_t count, size_t bytes)
{
    void *pointer;
    if (allocation_attempts++ == fail_at) {
        return NULL;
    }
    pointer = calloc(count, bytes);
    if (pointer != NULL) {
        outstanding_allocations++;
    }
    return pointer;
}

static void *test_realloc(void *old, size_t bytes)
{
    int creates_allocation = old == NULL;
    void *pointer;
    if (allocation_attempts++ == fail_at) {
        return NULL;
    }
    pointer = realloc(old, bytes);
    if (pointer != NULL && creates_allocation) {
        outstanding_allocations++;
    }
    return pointer;
}

static void test_free(void *pointer)
{
    if (pointer != NULL) {
        assert(outstanding_allocations > 0);
        outstanding_allocations--;
    }
    free(pointer);
}

#define malloc test_malloc
#define calloc test_calloc
#define realloc test_realloc
#define free test_free
#include "encoder.c"
#undef malloc
#undef calloc
#undef realloc
#undef free
#endif

static uint32_t read_u32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
        (uint32_t)bytes[2] << 8 | bytes[3];
}

static void assert_png(const svgpng_v1_png_output *output, const uint8_t *source,
    size_t stride, size_t width, size_t height, int require_multiple_idat)
{
    const uint8_t signature[] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    size_t position = 8, compressed_size = 0, idat_count = 0;
    size_t decoded_size = (width * 4 + 1) * height;
    uint8_t *compressed = malloc(output->length);
    uint8_t *decoded = malloc(decoded_size);
    uLongf inflated_size = (uLongf)decoded_size;
    int saw_header = 0, saw_end = 0;

    assert(compressed != NULL && decoded != NULL);
    assert(output->length >= 8 && memcmp(output->bytes, signature, 8) == 0);
    while (position < output->length) {
        const uint8_t *chunk;
        uint32_t length;
        uLong crc;
        assert(output->length - position >= 12);
        chunk = output->bytes + position;
        length = read_u32(chunk);
        assert(length <= output->length - position - 12);
        crc = crc32(0L, Z_NULL, 0);
        crc = crc32(crc, chunk + 4, length + 4);
        assert((uint32_t)crc == read_u32(chunk + 8 + length));
        if (!saw_header) {
            assert(position == 8 && length == 13 && memcmp(chunk + 4, "IHDR", 4) == 0);
            assert(read_u32(chunk + 8) == width && read_u32(chunk + 12) == height);
            assert(chunk[16] == 8 && chunk[17] == 6);
            assert(chunk[18] == 0 && chunk[19] == 0 && chunk[20] == 0);
            saw_header = 1;
        } else if (memcmp(chunk + 4, "IDAT", 4) == 0) {
            assert(!saw_end && length > 0 && length <= 32768);
            memcpy(compressed + compressed_size, chunk + 8, length);
            compressed_size += length;
            idat_count++;
        } else {
            assert(memcmp(chunk + 4, "IEND", 4) == 0);
            assert(idat_count > 0 && length == 0 && !saw_end);
            assert(position + 12 == output->length);
            saw_end = 1;
        }
        position += (size_t)length + 12;
    }
    assert(saw_header && saw_end && idat_count > 0);
    if (require_multiple_idat) {
        assert(idat_count > 1);
    }
    assert(uncompress(decoded, &inflated_size, compressed, (uLong)compressed_size) == Z_OK);
    assert(inflated_size == decoded_size);
    for (size_t row = 0; row < height; row++) {
        assert(decoded[row * (width * 4 + 1)] == 0);
        assert(memcmp(decoded + row * (width * 4 + 1) + 1, source + row * stride, width * 4) == 0);
    }
    free(decoded);
    free(compressed);
}

static void test_png_profile_and_ownership(void)
{
    const uint8_t source[] = {
        0xaa, 0, 7, 255, 0, 17, 128, 255, 128, 0xbb, 0xbb, 0xbb, 0xbb,
        255, 0, 128, 255, 2, 4, 6, 3, 0xcc, 0xcc, 0xcc, 0xcc, 0xdd
    };
    uint8_t snapshot[sizeof(source)];
    svgpng_v1_png_output first = { NULL, 0 }, second = { NULL, 0 };

    memcpy(snapshot, source, sizeof(source));
    assert(svgpng_v1_png_encode(source + 1, 24, 12, 2, 2, &first) == SVGPNG_V1_PNG_OK);
    assert_png(&first, source + 1, 12, 2, 2, 0);
    assert(svgpng_v1_png_encode(source + 1, 24, 12, 2, 2, &second) == SVGPNG_V1_PNG_OK);
    assert(first.bytes != second.bytes);
    assert(first.length == second.length && memcmp(first.bytes, second.bytes, first.length) == 0);
    assert(memcmp(source, snapshot, sizeof(source)) == 0);
    assert(svgpng_v1_png_encode(source + 1, 24, 12, 2, 2, &first) == SVGPNG_V1_PNG_INVALID_ARGUMENT);
    assert_png(&first, source + 1, 12, 2, 2, 0);
    svgpng_v1_png_free(&first);
    assert(first.bytes == NULL && first.length == 0);
    svgpng_v1_png_free(&first);
    svgpng_v1_png_free(&second);
    svgpng_v1_png_free(NULL);
}

static void test_multiple_idat(void)
{
    const size_t width = 256, height = 64, length = width * height * 4;
    uint32_t random = 0x12345678;
    uint8_t *source = malloc(length);
    svgpng_v1_png_output output = { NULL, 0 };
    assert(source != NULL);
    for (size_t i = 0; i < length; i++) {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        source[i] = (uint8_t)random;
    }
    assert(svgpng_v1_png_encode(source, length, width * 4, width, height, &output) == SVGPNG_V1_PNG_OK);
    assert_png(&output, source, width * 4, width, height, 1);
    svgpng_v1_png_free(&output);
    free(source);
}

static void test_preallocation_errors(void)
{
    const uint8_t source[] = { 0xaa, 1, 2, 3, 4, 0xbb };
    const uint8_t snapshot[] = { 0xaa, 1, 2, 3, 4, 0xbb };
    svgpng_v1_png_output output = { NULL, 0 };

#define EXPECT_ERROR(call, status) do { \
    assert((call) == (status)); \
    assert(output.bytes == NULL && output.length == 0); \
    assert(memcmp(source, snapshot, sizeof(source)) == 0); \
} while (0)
#define ENCODE(src, len, stride, w, h) \
    svgpng_v1_png_encode(src, len, stride, w, h, &output)

    EXPECT_ERROR(ENCODE(NULL, 4, 4, 1, 1), SVGPNG_V1_PNG_INVALID_ARGUMENT);
    EXPECT_ERROR(svgpng_v1_png_encode(source, 4, 4, 1, 1, NULL), SVGPNG_V1_PNG_INVALID_ARGUMENT);
    EXPECT_ERROR(ENCODE(source, 4, 4, 0, 1), SVGPNG_V1_PNG_INVALID_ARGUMENT);
    EXPECT_ERROR(ENCODE(source, 4, 4, 1, 0), SVGPNG_V1_PNG_INVALID_ARGUMENT);
    EXPECT_ERROR(ENCODE(source, 4, 3, 1, 1), SVGPNG_V1_PNG_INVALID_ARGUMENT);
    EXPECT_ERROR(ENCODE(source, 3, 4, 1, 1), SVGPNG_V1_PNG_BUFFER_TOO_SMALL);
    EXPECT_ERROR(ENCODE(source, 11, 6, 1, 2), SVGPNG_V1_PNG_BUFFER_TOO_SMALL);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, SIZE_MAX, SIZE_MAX, 1), SVGPNG_V1_PNG_OVERFLOW);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, 8, 2, SIZE_MAX), SVGPNG_V1_PNG_OVERFLOW);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, SIZE_MAX, 1, 2), SVGPNG_V1_PNG_OVERFLOW);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, 131076, 32769, 1), SVGPNG_V1_PNG_LIMIT_EXCEEDED);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, 4, 1, 32769), SVGPNG_V1_PNG_LIMIT_EXCEEDED);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, 32004, 8001, 8000), SVGPNG_V1_PNG_LIMIT_EXCEEDED);
    EXPECT_ERROR(ENCODE(source, SIZE_MAX, 268435457, 1, 1), SVGPNG_V1_PNG_LIMIT_EXCEEDED);

#undef ENCODE
#undef EXPECT_ERROR
}

#ifdef SVGPNG_ENCODER_FAULT_TEST
static void test_allocation_failure_cleanup(void)
{
    const uint8_t source[] = { 1, 2, 3, 4 };
    svgpng_v1_png_output output = { NULL, 0 };
    size_t attempts;

    allocation_attempts = 0;
    assert(svgpng_v1_png_encode(source, 4, 4, 1, 1, &output) == SVGPNG_V1_PNG_OK);
    attempts = allocation_attempts;
    svgpng_v1_png_free(&output);
    assert(outstanding_allocations == 0 && attempts > 3);
    for (size_t failure = 0; failure < attempts; failure++) {
        allocation_attempts = 0;
        fail_at = failure;
        assert(svgpng_v1_png_encode(source, 4, 4, 1, 1, &output) == SVGPNG_V1_PNG_ALLOCATION_FAILED);
        assert(output.bytes == NULL && output.length == 0);
        assert(outstanding_allocations == 0);
    }
    fail_at = SIZE_MAX;
}

static void test_output_bounds(void)
{
    png_encoding_state *state = calloc(1, sizeof(*state));
    uint8_t byte = 0;
    assert(state != NULL);
    state->png = png_create_write_struct_2(PNG_LIBPNG_VER_STRING, state,
        encoder_error, encoder_warning, state, encoder_allocate, encoder_release);
    assert(state->png != NULL);
    png_set_write_fn(state->png, state, encoder_write, encoder_flush);
    state->length = SIZE_MAX;
    if (setjmp(png_jmpbuf(state->png)) == 0) {
        encoder_write(state->png, &byte, 1);
        assert(0 && "overflow must raise a libpng error");
    }
    assert(state->status == SVGPNG_V1_PNG_OVERFLOW);
    assert(state->bytes == NULL && state->capacity == 0);
    state->status = SVGPNG_V1_PNG_OK;
    state->length = SVGPNG_PNG_MAX_BUFFER;
    if (setjmp(png_jmpbuf(state->png)) == 0) {
        encoder_write(state->png, &byte, 1);
        assert(0 && "output limit must raise a libpng error");
    }
    assert(state->status == SVGPNG_V1_PNG_LIMIT_EXCEEDED);
    assert(state->bytes == NULL && state->capacity == 0);
    png_destroy_write_struct(&state->png, &state->info);
    free(state);
    assert(outstanding_allocations == 0);
}
#endif

int main(void)
{
    test_preallocation_errors();
    test_png_profile_and_ownership();
    test_multiple_idat();
#ifdef SVGPNG_ENCODER_FAULT_TEST
    test_allocation_failure_cleanup();
    test_output_bounds();
    assert(outstanding_allocations == 0);
#endif
    puts("PNG encoder assertions passed");
    return 0;
}
