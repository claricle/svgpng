#ifndef SVGPNG_RENDERER_H
#define SVGPNG_RENDERER_H
#include <stddef.h>
#include <stdint.h>
/* All input memory is borrowed for the synchronous call. Output memory belongs
 * to Rust and must only be released by svgpng_v1_render_free. No shared globals. */
typedef struct {
  const uint8_t *bytes; size_t length;
  const uint8_t *requested_family; size_t family_length;
  const uint8_t *source_id; size_t source_id_length;
  size_t fallback_order; /* SIZE_MAX means exact-family use only. */
} svgpng_v1_font;
typedef struct {
  uint32_t abi_version, width, height, background_rgba;
  double intrinsic_width, intrinsic_height, fit, translate_x, translate_y;
} svgpng_v1_render_options;
typedef struct {
  uint8_t *pixels; size_t pixels_length;
  uint8_t *diagnostics; size_t diagnostics_length;
} svgpng_v1_render_output;
int svgpng_v1_root_attributes(const uint8_t *, size_t, svgpng_v1_render_output *);
int svgpng_v1_render(const uint8_t *, size_t, const svgpng_v1_font *, size_t,
                     const svgpng_v1_render_options *, svgpng_v1_render_output *);
void svgpng_v1_render_free(svgpng_v1_render_output *);
#endif
