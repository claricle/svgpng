#include "encoder.h"

#include <png.h>
#include <zlib.h>

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#if PNG_LIBPNG_VER != 10659
#error "svgpng requires libpng 1.6.59"
#endif
#if ZLIB_VERNUM != 0x1320
#error "svgpng requires zlib 1.3.2"
#endif
#ifndef PNG_USER_MEM_SUPPORTED
#error "svgpng requires libpng user memory callbacks"
#endif
#ifndef PNG_SETJMP_SUPPORTED
#error "svgpng requires libpng setjmp support"
#endif

#define SVGPNG_PNG_MAX_DIMENSION ((size_t)32768)
#define SVGPNG_PNG_MAX_PIXELS ((size_t)64000000)
#define SVGPNG_PNG_MAX_BUFFER ((size_t)268435456)

typedef union png_allocation_header {
    max_align_t alignment;
    size_t bytes;
} png_allocation_header;

/* Heap state survives longjmp; no modified automatic value is read afterwards. */
typedef struct png_encoding_state {
    png_structp png;
    png_infop info;
    uint8_t *bytes;
    size_t length;
    size_t capacity;
    size_t library_bytes;
    svgpng_v1_png_status status;
} png_encoding_state;

static png_voidp PNGCBAPI encoder_allocate(png_structp png, png_alloc_size_t bytes)
{
    png_encoding_state *state = png_get_mem_ptr(png);
    png_allocation_header *allocation;
    size_t allocation_bytes;

    if ((uintmax_t)bytes > SIZE_MAX - sizeof(*allocation)) {
        state->status = SVGPNG_V1_PNG_OVERFLOW;
        return NULL;
    }
    allocation_bytes = (size_t)bytes + sizeof(*allocation);
    if (allocation_bytes > SVGPNG_PNG_MAX_BUFFER - state->library_bytes) {
        state->status = SVGPNG_V1_PNG_LIMIT_EXCEEDED;
        return NULL;
    }
    allocation = malloc(allocation_bytes);
    if (allocation == NULL) {
        state->status = SVGPNG_V1_PNG_ALLOCATION_FAILED;
        return NULL;
    }
    allocation->bytes = allocation_bytes;
    state->library_bytes += allocation_bytes;
    return allocation + 1;
}

static void PNGCBAPI encoder_release(png_structp png, png_voidp pointer)
{
    png_encoding_state *state = png_get_mem_ptr(png);
    if (pointer != NULL) {
        png_allocation_header *allocation = (png_allocation_header *)pointer - 1;
        state->library_bytes -= allocation->bytes;
        free(allocation);
    }
}

static void PNGCBAPI encoder_error(png_structp png, png_const_charp message)
{
    png_encoding_state *state = png_get_error_ptr(png);
    (void)message;
    if (state->status == SVGPNG_V1_PNG_OK) {
        state->status = SVGPNG_V1_PNG_ENCODING_FAILED;
    }
    png_longjmp(png, 1);
}

static void PNGCBAPI encoder_warning(png_structp png, png_const_charp message)
{
    png_encoding_state *state = png_get_error_ptr(png);
    (void)message;
    /* zlib allocation warnings must return so deflateInit2 can release its
     * partial state. Fail the encode afterwards, including recovered warnings
     * that could otherwise silently change the byte profile. */
    if (state->status == SVGPNG_V1_PNG_OK) {
        state->status = SVGPNG_V1_PNG_ENCODING_FAILED;
    }
}

static void PNGCBAPI encoder_write(png_structp png, png_bytep bytes, png_size_t length)
{
    png_encoding_state *state = png_get_io_ptr(png);
    size_t required, capacity;
    uint8_t *replacement;

    if ((uintmax_t)length > SIZE_MAX - state->length) {
        state->status = SVGPNG_V1_PNG_OVERFLOW;
        png_error(png, "PNG output size overflow");
        return;
    }
    required = state->length + (size_t)length;
    if (required > SVGPNG_PNG_MAX_BUFFER) {
        state->status = SVGPNG_V1_PNG_LIMIT_EXCEEDED;
        png_error(png, "PNG output exceeds buffer limit");
        return;
    }
    if (required > state->capacity) {
        capacity = state->capacity == 0 ? 32768 : state->capacity;
        while (capacity < required) {
            capacity = capacity > SVGPNG_PNG_MAX_BUFFER / 2
                ? SVGPNG_PNG_MAX_BUFFER : capacity * 2;
        }
        replacement = realloc(state->bytes, capacity);
        if (replacement == NULL) {
            state->status = SVGPNG_V1_PNG_ALLOCATION_FAILED;
            png_error(png, "PNG output allocation failed");
            return;
        }
        state->bytes = replacement;
        state->capacity = capacity;
    }
    if (length != 0) {
        memcpy(state->bytes + state->length, bytes, (size_t)length);
    }
    state->length = required;
}

static void PNGCBAPI encoder_flush(png_structp png)
{
    (void)png;
}

static svgpng_v1_png_status encode_rows(
    png_encoding_state *state, const uint8_t *source, size_t source_stride,
    size_t width, size_t height)
{
    if (setjmp(png_jmpbuf(state->png)) != 0) {
        return state->status;
    }
    state->info = png_create_info_struct(state->png);
    if (state->info == NULL) {
        return state->status == SVGPNG_V1_PNG_OK
            ? SVGPNG_V1_PNG_ALLOCATION_FAILED : state->status;
    }
    png_set_write_fn(state->png, state, encoder_write, encoder_flush);
    png_set_IHDR(state->png, state->info, (png_uint_32)width, (png_uint_32)height,
        8, PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_BASE, PNG_FILTER_TYPE_BASE);
    png_set_filter(state->png, PNG_FILTER_TYPE_BASE, PNG_FILTER_NONE);
    png_set_compression_level(state->png, 9);
    png_set_compression_strategy(state->png, Z_DEFAULT_STRATEGY);
    png_set_compression_window_bits(state->png, 15);
    png_set_compression_mem_level(state->png, 8);
    png_set_compression_buffer_size(state->png, 32768);
    png_write_info(state->png, state->info);
    for (size_t row = 0; row < height; row++) {
        png_write_row(state->png, source + row * source_stride);
    }
    png_write_end(state->png, state->info);
    return state->status;
}

svgpng_v1_png_status svgpng_v1_png_encode(
    const uint8_t *source, size_t source_length, size_t source_stride,
    size_t width, size_t height, svgpng_v1_png_output *output)
{
    size_t source_bytes;
    png_encoding_state *state;
    svgpng_v1_png_status status;

    if (output == NULL || source == NULL || width == 0 || height == 0 ||
        output->bytes != NULL || output->length != 0) {
        return SVGPNG_V1_PNG_INVALID_ARGUMENT;
    }
    if (width > SIZE_MAX / 4 || width > SIZE_MAX / height) {
        return SVGPNG_V1_PNG_OVERFLOW;
    }
    if (source_stride < width * 4) {
        return SVGPNG_V1_PNG_INVALID_ARGUMENT;
    }
    if (source_stride > SIZE_MAX / height) {
        return SVGPNG_V1_PNG_OVERFLOW;
    }
    source_bytes = source_stride * height;
    if (width > SVGPNG_PNG_MAX_DIMENSION || height > SVGPNG_PNG_MAX_DIMENSION ||
        width * height > SVGPNG_PNG_MAX_PIXELS || source_bytes > SVGPNG_PNG_MAX_BUFFER) {
        return SVGPNG_V1_PNG_LIMIT_EXCEEDED;
    }
    if (source_length < source_bytes) {
        return SVGPNG_V1_PNG_BUFFER_TOO_SMALL;
    }
    if (source_bytes > UINTPTR_MAX - (uintptr_t)source) {
        return SVGPNG_V1_PNG_OVERFLOW;
    }
    if (png_access_version_number() != 10659 || strcmp(zlibVersion(), "1.3.2") != 0) {
        return SVGPNG_V1_PNG_VERSION_MISMATCH;
    }
    state = calloc(1, sizeof(*state));
    if (state == NULL) {
        return SVGPNG_V1_PNG_ALLOCATION_FAILED;
    }
    state->png = png_create_write_struct_2(PNG_LIBPNG_VER_STRING, state,
        encoder_error, encoder_warning, state, encoder_allocate, encoder_release);
    if (state->png == NULL) {
        status = state->status == SVGPNG_V1_PNG_OK
            ? SVGPNG_V1_PNG_ALLOCATION_FAILED : state->status;
    } else {
        status = encode_rows(state, source, source_stride, width, height);
        png_destroy_write_struct(&state->png, &state->info);
    }
    if (status == SVGPNG_V1_PNG_OK) {
        output->bytes = state->bytes;
        output->length = state->length;
    } else {
        free(state->bytes);
    }
    free(state);
    return status;
}

void svgpng_v1_png_free(svgpng_v1_png_output *output)
{
    if (output != NULL) {
        free(output->bytes);
        output->bytes = NULL;
        output->length = 0;
    }
}
