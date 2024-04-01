#pragma once

//#include "base/buffer_vector.hpp"

#include <vector>

#include <hb.h>

// Now the font is autodetected from the codepoint.
// TODO:(AB): Pass custom fonts to render with a fallback.
struct FontParams {
  int pixelSize;
  int8_t lang;
};

struct TextRun
{
  std::u16string_view run;
  hb_script_t script;
  int font;
  // TextRun() = default;
  TextRun(std::u16string_view run, hb_script_t script, int font) : run(run), script(script), font(font) {}
};

struct TextRuns
{
  //buffer_vector<TextRun, 10> runs;
  std::u16string text;
  std::vector<TextRun> runs;
};

TextRuns ItemizeAndShapeText(std::string_view utf8, FontParams const & fontParams);
