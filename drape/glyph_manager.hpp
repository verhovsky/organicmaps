#pragma once

#include "base/shared_buffer_manager.hpp"
#include "base/string_utils.hpp"

#include "drape/glyph.hpp"

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace dp
{
struct UnicodeBlock;

class GlyphManager
{
public:
  struct Params
  {
    std::string m_uniBlocks;
    std::string m_whitelist;
    std::string m_blacklist;

    std::vector<std::string> m_fonts;

    uint32_t m_baseGlyphHeight = 22;
    uint32_t m_sdfScale = 4;
  };

  explicit GlyphManager(Params const & params);
  ~GlyphManager();

  GlyphManager(GlyphManager const & params) = delete;
  GlyphManager(GlyphManager && params) = delete;
  GlyphManager & operator=(GlyphManager const &) = delete;
  GlyphManager & operator=(GlyphManager &&) = delete;

  Glyph GetGlyph(strings::UniChar unicodePoints, int fixedHeight);

  void MarkGlyphReady(Glyph const & glyph);
  bool AreGlyphsReady(strings::UniString const & str, int fixedSize) const;

  Glyph GetInvalidGlyph(int fixedSize) const;

  uint32_t GetBaseGlyphHeight() const;
  uint32_t GetSdfScale() const;

  static Glyph GenerateGlyph(Glyph const & glyph, uint32_t sdfScale);

private:
  int GetFontIndex(strings::UniChar unicodePoint);
  // Immutable version can be called from any thread and doesn't require internal synchronization.
  int GetFontIndexImmutable(strings::UniChar unicodePoint) const;
  int FindFontIndexInBlock(UnicodeBlock const & block, strings::UniChar unicodePoint) const;

private:
  struct Impl;
  std::unique_ptr<Impl> m_impl;
};
}  // namespace dp
