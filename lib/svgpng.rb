# frozen_string_literal: true

require_relative "svgpng/version"
require_relative "svgpng/errors"
require_relative "svgpng/limits"
require_relative "svgpng/font_face"
require_relative "svgpng/font_inputs"
require_relative "svgpng/result"
require_relative "svgpng/font_warnings"
require_relative "svgpng/raw_input"
require_relative "svgpng/render_profile"
require_relative "svgpng/renderer"

## Public byte-oriented rendering boundary.
module Svgpng
  def self.render(svg_bytes, profile:, fonts:, fallback_fonts:)
    Renderer.render(svg_bytes, profile: profile, fonts: fonts, fallback_fonts: fallback_fonts)
  end
end
