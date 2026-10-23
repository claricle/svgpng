# frozen_string_literal: true

# Helpers scoped explicitly to the real-artifact integration examples.
module NativeFontRenderingHelpers
  def font_face(filename, source_id)
    Svgpng::FontFace.new(bytes: File.binread(File.join(font_directory, filename)), source_id: source_id)
  end

  def render_text(text, family: "Noto Sans", weight: 400, fonts: {}, fallback_fonts: [])
    body = %(<text font-family="#{family}" font-weight="#{weight}" x="2" y="30">#{text}</text>)
    render_body(body, fonts: fonts, fallback_fonts: fallback_fonts)
  end

  def render_body(body, fonts: {}, fallback_fonts: [])
    source = %(<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40">#{body}</svg>)
    Svgpng.render(source, profile: {}, fonts: fonts, fallback_fonts: fallback_fonts)
  end

  def metadata(face, family:, weight: 400)
    { "family" => family, "source_id" => face.source_id, "sha256" => face.sha256,
      "face_index" => 0, "style" => "normal", "weight" => weight, "stretch" => "normal" }
  end

  def warning_fields(warning)
    %i[requested_family selected_family style weight stretch scalars].map { |field| warning.public_send(field) }
  end
end
