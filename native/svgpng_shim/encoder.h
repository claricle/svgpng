#ifndef SVGPNG_ENCODER_H
#define SVGPNG_ENCODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum svgpng_v1_png_status {
    SVGPNG_V1_PNG_OK = 0,
    SVGPNG_V1_PNG_INVALID_ARGUMENT = 1,
    SVGPNG_V1_PNG_OVERFLOW = 2,
    SVGPNG_V1_PNG_LIMIT_EXCEEDED = 3,
    SVGPNG_V1_PNG_BUFFER_TOO_SMALL = 4,
    SVGPNG_V1_PNG_ALLOCATION_FAILED = 5,
    SVGPNG_V1_PNG_ENCODING_FAILED = 6,
    SVGPNG_V1_PNG_VERSION_MISMATCH = 7
} svgpng_v1_png_status;

typedef struct svgpng_v1_png_output {
    uint8_t *bytes;
    size_t length;
} svgpng_v1_png_output;

/* Encode top-to-bottom straight RGBA8, without modifying source or padding.
 * source_length must cover source_stride * height, including final padding.
 * output must initially be {NULL, 0}; errors preserve that empty value. An
 * invalid nonempty output is left unchanged. On success its
 * bytes belong to the shim and must be released with svgpng_v1_png_free.
 * No profile/gamma conversion or background compositing takes place here.
 */
svgpng_v1_png_status svgpng_v1_png_encode(
    const uint8_t *source, size_t source_length, size_t source_stride,
    size_t width, size_t height, svgpng_v1_png_output *output);

/* Accepts NULL or an empty output, and resets a released output to {NULL, 0}. */
void svgpng_v1_png_free(svgpng_v1_png_output *output);

#ifdef __cplusplus
}
#endif

#endif
