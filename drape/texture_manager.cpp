#include "drape/texture_manager.hpp"

#include "drape/gl_functions.hpp"
#include "drape/font_texture.hpp"
#include "drape/symbols_texture.hpp"
#include "drape/static_texture.hpp"
#include "drape/stipple_pen_resource.hpp"
#include "drape/support_manager.hpp"
#include "drape/texture_of_colors.hpp"
#include "drape/tm_read_resources.hpp"
#include "drape/utils/glyph_usage_tracker.hpp"

#include "base/file_name_utils.hpp"
#include "base/stl_helpers.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace dp
{
namespace
{
uint32_t constexpr kMaxTextureSize = 1024;
uint32_t constexpr kStippleTextureWidth = 512;  /// @todo Should be equal with kMaxStipplePenLength?
uint32_t constexpr kMinStippleTextureHeight = 64;
uint32_t constexpr kMinColorTextureSize = 32;
uint32_t constexpr kGlyphsTextureSize = 1024;
size_t constexpr kInvalidGlyphGroup = std::numeric_limits<size_t>::max();

// Reserved for elements like RuleDrawer or other LineShapes.
uint32_t constexpr kReservedPatterns = 10;
size_t constexpr kReservedColors = 20;

float constexpr kGlyphAreaMultiplier = 1.2f;
float constexpr kGlyphAreaCoverage = 0.9f;

std::string const kSymbolTextures[] = { "symbols" };
uint32_t constexpr kDefaultSymbolsIndex = 0;

void MultilineTextToUniString(TextureManager::TMultilineText const & text, strings::UniString & outString)
{
  size_t cnt = 0;
  for (strings::UniString const & str : text)
    cnt += str.size();

  outString.clear();
  outString.reserve(cnt);
  for (strings::UniString const & str : text)
    outString.append(str.begin(), str.end());
}

template <typename ToDo>
void ParseColorsList(std::string const & colorsFile, ToDo toDo)
{
  ReaderStreamBuf buffer(GetPlatform().GetReader(colorsFile));
  std::istream is(&buffer);
  while (is.good())
  {
    uint32_t color;
    is >> color;
    toDo(dp::Color::FromARGB(color));
  }
}

m2::PointU StipplePenTextureSize(size_t patternsCount, uint32_t maxTextureSize)
{
  uint32_t const sz = base::NextPowOf2(static_cast<uint32_t>(patternsCount) + kReservedPatterns);
  // No problem if assert will fire here. Just pen texture will be 2x bigger :)
  //ASSERT_LESS_OR_EQUAL(sz, kMinStippleTextureHeight, (patternsCount));
  uint32_t const stippleTextureHeight = std::min(maxTextureSize, std::max(sz, kMinStippleTextureHeight));

  return m2::PointU(kStippleTextureWidth, stippleTextureHeight);
}

m2::PointU ColorTextureSize(size_t colorsCount, uint32_t maxTextureSize)
{
  uint32_t const sz = static_cast<uint32_t>(floor(sqrt(colorsCount + kReservedColors)));
  // No problem if assert will fire here. Just color texture will be 2x bigger :)
  ASSERT_LESS_OR_EQUAL(sz, kMinColorTextureSize, (colorsCount));
  uint32_t colorTextureSize = std::max(base::NextPowOf2(sz), kMinColorTextureSize);

  colorTextureSize *= ColorTexture::GetColorSizeInPixels();
  colorTextureSize = std::min(maxTextureSize, colorTextureSize);
  return m2::PointU(colorTextureSize, colorTextureSize);
}

drape_ptr<Texture> CreateArrowTexture(ref_ptr<dp::GraphicsContext> context,
                                      ref_ptr<HWTextureAllocator> textureAllocator,
                                      std::optional<std::string> const & texturePath,
                                      bool useDefaultResourceFolder)
{
  if (texturePath.has_value())
  {
    return make_unique_dp<StaticTexture>(
        context, texturePath.value(),
        useDefaultResourceFolder ? std::make_optional(StaticTexture::kDefaultResource)
                                 : std::nullopt /* skinPathName */,
        dp::TextureFormat::RGBA8, textureAllocator, true /* allowOptional */);
  }
  return make_unique_dp<StaticTexture>(context, "arrow-texture.png",
                                       StaticTexture::kDefaultResource, dp::TextureFormat::RGBA8,
                                       textureAllocator, true /* allowOptional */);
}
}  // namespace

TextureManager::TextureManager(ref_ptr<GlyphGenerator> glyphGenerator)
  : m_maxTextureSize(0)
  , m_maxGlypsCount(0)
  , m_glyphGenerator(glyphGenerator)
{
  m_nothingToUpload.test_and_set();
}

TextureManager::BaseRegion::BaseRegion()
  : m_info(nullptr)
  , m_texture(nullptr)
{}

bool TextureManager::BaseRegion::IsValid() const
{
  return m_info != nullptr && m_texture != nullptr;
}

void TextureManager::BaseRegion::SetResourceInfo(ref_ptr<Texture::ResourceInfo> info)
{
  m_info = info;
}

void TextureManager::BaseRegion::SetTexture(ref_ptr<Texture> texture)
{
  m_texture = texture;
}

m2::PointF TextureManager::BaseRegion::GetPixelSize() const
{
  if (!IsValid())
    return m2::PointF(0.0f, 0.0f);

  m2::RectF const & texRect = m_info->GetTexRect();
  return m2::PointF(texRect.SizeX() * m_texture->GetWidth(),
                    texRect.SizeY() * m_texture->GetHeight());
}

float TextureManager::BaseRegion::GetPixelHeight() const
{
  if (!IsValid())
    return 0.0f;

  return m_info->GetTexRect().SizeY() * m_texture->GetHeight();
}

m2::RectF const & TextureManager::BaseRegion::GetTexRect() const
{
  if (!IsValid())
  {
    static m2::RectF constexpr kNilRect{0.0f, 0.0f, 0.0f, 0.0f};
    return kNilRect;
  }

  return m_info->GetTexRect();
}

float TextureManager::GlyphRegion::GetOffsetX() const
{
  ASSERT(m_info->GetType() == Texture::ResourceType::Glyph, ());
  return ref_ptr<GlyphInfo>(m_info)->GetMetrics().m_xOffset;
}

float TextureManager::GlyphRegion::GetOffsetY() const
{
  ASSERT(m_info->GetType() == Texture::ResourceType::Glyph, ());
  return ref_ptr<GlyphInfo>(m_info)->GetMetrics().m_yOffset;
}

float TextureManager::GlyphRegion::GetAdvanceX() const
{
  ASSERT(m_info->GetType() == Texture::ResourceType::Glyph, ());
  return ref_ptr<GlyphInfo>(m_info)->GetMetrics().m_xAdvance;
}

float TextureManager::GlyphRegion::GetAdvanceY() const
{
  ASSERT(m_info->GetType() == Texture::ResourceType::Glyph, ());
  return ref_ptr<GlyphInfo>(m_info)->GetMetrics().m_yAdvance;
}

m2::PointU TextureManager::StippleRegion::GetMaskPixelSize() const
{
  ASSERT(m_info->GetType() == Texture::ResourceType::StipplePen, ());
  return ref_ptr<StipplePenResourceInfo>(m_info)->GetMaskPixelSize();
}

//uint32_t TextureManager::StippleRegion::GetPatternPixelLength() const
//{
//  ASSERT(m_info->GetType() == Texture::ResourceType::StipplePen, ());
//  return ref_ptr<StipplePenResourceInfo>(m_info)->GetPatternPixelLength();
//}

void TextureManager::Release()
{
  m_hybridGlyphGroups.clear();

  m_symbolTextures.clear();
  m_stipplePenTexture.reset();
  m_colorTexture.reset();

  m_trafficArrowTexture.reset();
  m_hatchingTexture.reset();
  m_arrowTexture.reset();
  m_smaaAreaTexture.reset();
  m_smaaSearchTexture.reset();

  m_glyphTextures.clear();

  m_glyphManager.reset();

  m_glyphGenerator->FinishGeneration();

  m_isInitialized = false;
  m_nothingToUpload.test_and_set();
}

bool TextureManager::UpdateDynamicTextures(ref_ptr<dp::GraphicsContext> context)
{
  if (!HasAsyncRoutines() && m_nothingToUpload.test_and_set())
  {
    auto const apiVersion = context->GetApiVersion();
    if (apiVersion == dp::ApiVersion::OpenGLES2 || apiVersion == dp::ApiVersion::OpenGLES3)
    {
      // For some reasons OpenGL can not update textures immediately.
      // Here we use some timeout to prevent rendering frozening.
      double const kUploadTimeoutInSeconds = 2.0;
      return m_uploadTimer.ElapsedSeconds() < kUploadTimeoutInSeconds;
    }

    if (apiVersion == dp::ApiVersion::Metal || apiVersion == dp::ApiVersion::Vulkan)
      return false;

    CHECK(false, ("Unsupported API version."));
  }

  CHECK(m_isInitialized, ());

  m_uploadTimer.Reset();

  CHECK(m_colorTexture != nullptr, ());
  m_colorTexture->UpdateState(context);

  CHECK(m_stipplePenTexture != nullptr, ());
  m_stipplePenTexture->UpdateState(context);

  UpdateGlyphTextures(context);

  CHECK(m_textureAllocator != nullptr, ());
  m_textureAllocator->Flush();

  return true;
}

void TextureManager::UpdateGlyphTextures(ref_ptr<dp::GraphicsContext> context)
{
  std::lock_guard<std::mutex> lock(m_glyphTexturesMutex);
  for (auto & texture : m_glyphTextures)
    texture->UpdateState(context);
}

bool TextureManager::HasAsyncRoutines() const
{
  CHECK(m_glyphGenerator != nullptr, ());
  return !m_glyphGenerator->IsSuspended();
}

ref_ptr<Texture> TextureManager::AllocateGlyphTexture()
{
  std::lock_guard const lock(m_glyphTexturesMutex);
  m2::PointU size(kGlyphsTextureSize, kGlyphsTextureSize);
  m_glyphTextures.push_back(make_unique_dp<FontTexture>(size, make_ref(m_glyphManager),
                                                        m_glyphGenerator,
                                                        make_ref(m_textureAllocator)));
  return make_ref(m_glyphTextures.back());
}

void TextureManager::GetRegionBase(ref_ptr<Texture> tex, TextureManager::BaseRegion & region,
                                   Texture::Key const & key)
{
  bool isNew = false;
  region.SetResourceInfo(tex != nullptr ? tex->FindResource(key, isNew) : nullptr);
  region.SetTexture(tex);
  ASSERT(region.IsValid(), ());
  if (isNew)
    m_nothingToUpload.clear();
}

void TextureManager::GetGlyphsRegions(ref_ptr<FontTexture> tex, strings::UniString const & text,
                                      int fixedHeight, TGlyphsBuffer & regions)
{
  ASSERT(tex != nullptr, ());

  std::vector<GlyphKey> keys;
  keys.reserve(text.size());
  for (auto const c : text)
    keys.emplace_back(c, fixedHeight);

  bool hasNew = false;
  auto resourcesInfo = tex->FindResources(keys, hasNew);
  ASSERT_EQUAL(text.size(), resourcesInfo.size(), ());

  regions.reserve(resourcesInfo.size());
  for (auto const & info : resourcesInfo)
  {
    GlyphRegion reg;
    reg.SetResourceInfo(info);
    reg.SetTexture(tex);
    ASSERT(reg.IsValid(), ());

    regions.push_back(std::move(reg));
  }

  if (hasNew)
    m_nothingToUpload.clear();
}

uint32_t TextureManager::GetNumberOfUnfoundCharacters(strings::UniString const & text, int fixedHeight,
                                                      HybridGlyphGroup const & group)
{
  uint32_t cnt = 0;
  for (auto const & c : text)
  {
    if (group.m_glyphs.find(std::make_pair(c, fixedHeight)) == group.m_glyphs.end())
      cnt++;
  }

  return cnt;
}

void TextureManager::MarkCharactersUsage(strings::UniString const & text, int fixedHeight,
                                         HybridGlyphGroup & group)
{
  for (auto const & c : text)
    group.m_glyphs.emplace(c, fixedHeight);
}

size_t TextureManager::FindHybridGlyphsGroup(strings::UniString const & text, int fixedHeight)
{
  if (m_hybridGlyphGroups.empty())
  {
    m_hybridGlyphGroups.push_back(HybridGlyphGroup());
    return 0;
  }

  HybridGlyphGroup & group = m_hybridGlyphGroups.back();
  bool hasEnoughSpace = true;
  if (group.m_texture != nullptr)
    hasEnoughSpace = group.m_texture->HasEnoughSpace(static_cast<uint32_t>(text.size()));

  // If we have got the only hybrid texture (in most cases it is)
  // we can omit checking of glyphs usage.
  if (hasEnoughSpace)
  {
    size_t const glyphsCount = group.m_glyphs.size() + text.size();
    if (m_hybridGlyphGroups.size() == 1 && glyphsCount < m_maxGlypsCount)
      return 0;
  }

  // Looking for a hybrid texture which contains text entirely.
  for (size_t i = 0; i < m_hybridGlyphGroups.size() - 1; i++)
  {
    if (GetNumberOfUnfoundCharacters(text, fixedHeight, m_hybridGlyphGroups[i]) == 0)
      return i;
  }

  // Check if we can contain text in the last hybrid texture.
  uint32_t const unfoundChars = GetNumberOfUnfoundCharacters(text, fixedHeight, group);
  uint32_t const newCharsCount = static_cast<uint32_t>(group.m_glyphs.size()) + unfoundChars;
  if (newCharsCount >= m_maxGlypsCount || !group.m_texture->HasEnoughSpace(unfoundChars))
    m_hybridGlyphGroups.push_back(HybridGlyphGroup());

  return m_hybridGlyphGroups.size() - 1;
}

size_t TextureManager::FindHybridGlyphsGroup(TMultilineText const & text, int fixedHeight)
{
  strings::UniString combinedString;
  MultilineTextToUniString(text, combinedString);

  return FindHybridGlyphsGroup(combinedString, fixedHeight);
}

void TextureManager::Init(ref_ptr<dp::GraphicsContext> context, Params const & params)
{
  CHECK(!m_isInitialized, ());

  m_resPostfix = params.m_resPostfix;
  m_textureAllocator = CreateAllocator(context);

  m_maxTextureSize = std::min(kMaxTextureSize, dp::SupportManager::Instance().GetMaxTextureSize());
  auto const apiVersion = context->GetApiVersion();
  if (apiVersion == dp::ApiVersion::OpenGLES2 || apiVersion == dp::ApiVersion::OpenGLES3)
    GLFunctions::glPixelStore(gl_const::GLUnpackAlignment, 1);

  // Initialize symbols.
  for (auto const & texName : kSymbolTextures)
  {
    m_symbolTextures.push_back(make_unique_dp<SymbolsTexture>(context, m_resPostfix, texName,
                                                              make_ref(m_textureAllocator)));
  }

  // Initialize static textures.
  m_trafficArrowTexture =
      make_unique_dp<StaticTexture>(context, "traffic-arrow.png", m_resPostfix,
                                    dp::TextureFormat::RGBA8, make_ref(m_textureAllocator));
  m_hatchingTexture =
      make_unique_dp<StaticTexture>(context, "area-hatching.png", m_resPostfix,
                                    dp::TextureFormat::RGBA8, make_ref(m_textureAllocator));
  m_arrowTexture =
      CreateArrowTexture(context, make_ref(m_textureAllocator), params.m_arrowTexturePath,
                         params.m_arrowTextureUseDefaultResourceFolder);

  // SMAA is not supported on OpenGL ES2.
  if (apiVersion != dp::ApiVersion::OpenGLES2)
  {
    m_smaaAreaTexture =
        make_unique_dp<StaticTexture>(context, "smaa-area.png", StaticTexture::kDefaultResource,
                                      dp::TextureFormat::RedGreen, make_ref(m_textureAllocator));
    m_smaaSearchTexture =
        make_unique_dp<StaticTexture>(context, "smaa-search.png", StaticTexture::kDefaultResource,
                                      dp::TextureFormat::Alpha, make_ref(m_textureAllocator));
  }

  // Initialize patterns (reserved ./data/patterns.txt lines count).
  std::set<PenPatternT> patterns;

  double const visualScale = params.m_visualScale;
  uint32_t rowsCount = 0;
  impl::ParsePatternsList(params.m_patterns, [&](buffer_vector<double, 8> const & pattern)
  {
    PenPatternT toAdd;
    for (double d : pattern)
      toAdd.push_back(PatternFloat2Pixel(d * visualScale));

    if (!patterns.insert(toAdd).second)
      return;

    if (IsTrianglePattern(toAdd))
    {
      rowsCount = rowsCount + toAdd[2] + toAdd[3];
    }
    else
    {
      ASSERT_EQUAL(toAdd.size(), 2, ());
      ++rowsCount;
    }
  });

  m_stipplePenTexture = make_unique_dp<StipplePenTexture>(StipplePenTextureSize(rowsCount, m_maxTextureSize),
                                                          make_ref(m_textureAllocator));

  LOG(LDEBUG, ("Patterns texture size =", m_stipplePenTexture->GetWidth(), m_stipplePenTexture->GetHeight()));

  ref_ptr<StipplePenTexture> stipplePenTex = make_ref(m_stipplePenTexture);
  for (auto const & p : patterns)
    stipplePenTex->ReservePattern(p);

  // Initialize colors (reserved ./data/colors.txt lines count).
  std::vector<dp::Color> colors;
  colors.reserve(512);
  ParseColorsList(params.m_colors, [&colors](dp::Color const & color)
  {
    colors.push_back(color);
  });

  m_colorTexture = make_unique_dp<ColorTexture>(ColorTextureSize(colors.size(), m_maxTextureSize),
                                                make_ref(m_textureAllocator));

  LOG(LDEBUG, ("Colors texture size =", m_colorTexture->GetWidth(), m_colorTexture->GetHeight()));

  ref_ptr<ColorTexture> colorTex = make_ref(m_colorTexture);
  for (auto const & c : colors)
    colorTex->ReserveColor(c);

  // Initialize glyphs.
  m_glyphManager = make_unique_dp<GlyphManager>(params.m_glyphMngParams);
  uint32_t constexpr textureSquare = kGlyphsTextureSize * kGlyphsTextureSize;
  uint32_t const baseGlyphHeight =
      static_cast<uint32_t>(params.m_glyphMngParams.m_baseGlyphHeight * kGlyphAreaMultiplier);
  uint32_t const averageGlyphSquare = baseGlyphHeight * baseGlyphHeight;
  m_maxGlypsCount = static_cast<uint32_t>(ceil(kGlyphAreaCoverage * textureSquare / averageGlyphSquare));

  m_isInitialized = true;
  m_nothingToUpload.clear();
}

void TextureManager::OnSwitchMapStyle(ref_ptr<dp::GraphicsContext> context)
{
  CHECK(m_isInitialized, ());

  // Here we need invalidate only textures which can be changed in map style switch.
  // Now we update only symbol textures, if we need update other textures they must be added here.
  // For Vulkan we use m_texturesToCleanup to defer textures destroying.
  for (size_t i = 0; i < m_symbolTextures.size(); ++i)
  {
    ref_ptr<SymbolsTexture> symbolsTexture = make_ref(m_symbolTextures[i]);
    ASSERT(symbolsTexture != nullptr, ());

    if (context->GetApiVersion() != dp::ApiVersion::Vulkan)
      symbolsTexture->Invalidate(context, m_resPostfix, make_ref(m_textureAllocator));
    else
      symbolsTexture->Invalidate(context, m_resPostfix, make_ref(m_textureAllocator), m_texturesToCleanup);
  }
}

void TextureManager::InvalidateArrowTexture(
    ref_ptr<dp::GraphicsContext> context,
    std::optional<std::string> const & texturePath /* = std::nullopt */,
    bool useDefaultResourceFolder /* = false */)
{
  CHECK(m_isInitialized, ());
  m_newArrowTexture = CreateArrowTexture(context, make_ref(m_textureAllocator), texturePath,
                                         useDefaultResourceFolder);
}

void TextureManager::ApplyInvalidatedStaticTextures()
{
  if (m_newArrowTexture)
  {
    std::swap(m_arrowTexture, m_newArrowTexture);
    m_newArrowTexture.reset();
  }
}

void TextureManager::GetTexturesToCleanup(std::vector<drape_ptr<HWTexture>> & textures)
{
  CHECK(m_isInitialized, ());
  std::swap(textures, m_texturesToCleanup);
}

bool TextureManager::GetSymbolRegionSafe(std::string const & symbolName, SymbolRegion & region)
{
  CHECK(m_isInitialized, ());
  for (size_t i = 0; i < m_symbolTextures.size(); ++i)
  {
    ref_ptr<SymbolsTexture> symbolsTexture = make_ref(m_symbolTextures[i]);
    ASSERT(symbolsTexture != nullptr, ());
    if (symbolsTexture->IsSymbolContained(symbolName))
    {
      GetRegionBase(symbolsTexture, region, SymbolsTexture::SymbolKey(symbolName));
      region.SetTextureIndex(static_cast<uint32_t>(i));
      return true;
    }
  }
  return false;
}

void TextureManager::GetSymbolRegion(std::string const & symbolName, SymbolRegion & region)
{
  if (!GetSymbolRegionSafe(symbolName, region))
    LOG(LWARNING, ("Detected using of unknown symbol ", symbolName));
}

void TextureManager::GetStippleRegion(PenPatternT const & pen, StippleRegion & region)
{
  CHECK(m_isInitialized, ());
  GetRegionBase(make_ref(m_stipplePenTexture), region, StipplePenKey(pen));
}

void TextureManager::GetColorRegion(Color const & color, ColorRegion & region)
{
  CHECK(m_isInitialized, ());
  GetRegionBase(make_ref(m_colorTexture), region, ColorKey(color));
}

void TextureManager::GetGlyphRegions(TMultilineText const & text, int fixedHeight,
                                     TMultilineGlyphsBuffer & buffers)
{
  std::lock_guard<std::mutex> lock(m_calcGlyphsMutex);
  CalcGlyphRegions<TMultilineText, TMultilineGlyphsBuffer>(text, fixedHeight, buffers);
}

void TextureManager::GetGlyphRegions(strings::UniString const & text, int fixedHeight,
                                     TGlyphsBuffer & regions)
{
  std::lock_guard<std::mutex> lock(m_calcGlyphsMutex);
  CalcGlyphRegions<strings::UniString, TGlyphsBuffer>(text, fixedHeight, regions);
}

/*
uint32_t TextureManager::GetAbsentGlyphsCount(ref_ptr<Texture> texture,
                                              strings::UniString const & text,
                                              int fixedHeight) const
{
  if (texture == nullptr)
    return 0;

  ASSERT(dynamic_cast<FontTexture *>(texture.get()) != nullptr, ());
  return static_cast<FontTexture *>(texture.get())->GetAbsentGlyphsCount(text, fixedHeight);
}

uint32_t TextureManager::GetAbsentGlyphsCount(ref_ptr<Texture> texture, TMultilineText const & text,
                                              int fixedHeight) const
{
  if (texture == nullptr)
    return 0;

  uint32_t count = 0;
  for (size_t i = 0; i < text.size(); ++i)
    count += GetAbsentGlyphsCount(texture, text[i], fixedHeight);
  return count;
}
*/

bool TextureManager::AreGlyphsReady(strings::UniString const & str, int fixedHeight) const
{
  CHECK(m_isInitialized, ());
  return m_glyphManager->AreGlyphsReady(str, fixedHeight);
}

ref_ptr<Texture> TextureManager::GetSymbolsTexture() const
{
  CHECK(m_isInitialized, ());
  ASSERT(!m_symbolTextures.empty(), ());
  return make_ref(m_symbolTextures[kDefaultSymbolsIndex]);
}

ref_ptr<Texture> TextureManager::GetTrafficArrowTexture() const
{
  CHECK(m_isInitialized, ());
  return make_ref(m_trafficArrowTexture);
}

ref_ptr<Texture> TextureManager::GetHatchingTexture() const
{
  CHECK(m_isInitialized, ());
  return make_ref(m_hatchingTexture);
}

ref_ptr<Texture> TextureManager::GetArrowTexture() const
{
  CHECK(m_isInitialized, ());
  if (m_newArrowTexture)
    return make_ref(m_newArrowTexture);

  return make_ref(m_arrowTexture);
}

ref_ptr<Texture> TextureManager::GetSMAAAreaTexture() const
{
  CHECK(m_isInitialized, ());
  return make_ref(m_smaaAreaTexture);
}

ref_ptr<Texture> TextureManager::GetSMAASearchTexture() const
{
  CHECK(m_isInitialized, ());
  return make_ref(m_smaaSearchTexture);
}

constexpr size_t TextureManager::GetInvalidGlyphGroup()
{
  return kInvalidGlyphGroup;
}
}  // namespace dp
