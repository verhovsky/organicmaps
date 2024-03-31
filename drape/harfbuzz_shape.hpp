#pragma once

// #include "base/buffer_vector.hpp"

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
  int32_t start, end;
  hb_script_t script;
  int font;
  //TextRun() = default;
  TextRun(int32_t start, int32_t end, hb_script_t script, int font) : start(start), end(end), script(script), font(font) {}
};

struct TextRuns
{
  //buffer_vector<TextRun, 10> runs;
  std::u16string text;
  std::vector<TextRun> runs;
};

TextRuns ItemizeAndShapeText(std::string_view utf8, FontParams const & fontParams);
