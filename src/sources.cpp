#include "app.h"
#include <d3dcompiler.h>
#include <mfapi.h>
#include <mfmediaengine.h>
#include <shlobj.h>
#include <wincodec.h>
#include <algorithm>
#include <cmath>

// ============================================================================================
// Shader wallpapers
// ============================================================================================

// Wrapped around every user shader. Users write: float4 mainImage(float2 fragCoord)
static const char kShaderHeader[] = R"(
cbuffer Globals : register(b0) { float2 iResolution; float iTime; float iFrame; float4 _uvXform; float4 _adjust; float4 _rainbow; float4 iDate; };
Texture2D iChannel0 : register(t0);  // images named by "// texture:" and "// texture1:" lines, if any
Texture2D iChannel1 : register(t1);
SamplerState iSampler : register(s0);
#define vec2 float2
#define vec3 float3
#define vec4 float4
#define mix lerp
#define fract frac
float  glsl_mod(float x, float y)   { return x - y * floor(x / y); }
float2 glsl_mod(float2 x, float y)  { return x - y * floor(x / y); }
float3 glsl_mod(float3 x, float y)  { return x - y * floor(x / y); }
float2 glsl_mod(float2 x, float2 y) { return x - y * floor(x / y); }
float3 glsl_mod(float3 x, float3 y) { return x - y * floor(x / y); }
#define mod glsl_mod
)";

static const char kShaderFooter[] = R"(
// Settings window color controls: _adjust = (hue radians, saturation, brightness).
float3 _Adjust(float3 c) {
    if (_adjust.x != 0) {
        const float3 k = float3(0.57735, 0.57735, 0.57735);
        float ca = cos(_adjust.x);
        c = c * ca + cross(k, c) * sin(_adjust.x) + k * dot(k, c) * (1 - ca);
    }
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    return saturate(lerp(l.xxx, c, _adjust.y) * _adjust.z);
}

// Settings window RGB rainbow: _rainbow = (hue angle, wave across the screen, on). Same as Rainbow()
// in rainbow.hlsli.
float3 _Rainbow(float3 c, float2 fragCoord) {
    if (_rainbow.z == 0) return c;
    float a = _rainbow.x + _rainbow.y * fragCoord.x / iResolution.x;
    const float3 k = float3(0.57735, 0.57735, 0.57735);
    float ca = cos(a);
    float3 r = c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1 - ca);
    // Turning hues leaves greys and whites as they are, so those take on the rainbow's color too.
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    float grey = hi > 0 ? 1 - (hi - lo) / hi : 1;
    float3 tint = (0.5 + 0.5 * cos(a + float3(0, 2.0944, 4.1888))) * dot(c, float3(0.2126, 0.7152, 0.0722)) * 2;
    return lerp(r, tint, grey * 0.65);
}

float4 PSMain(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    float2 fragCoord = float2(pos.x, iResolution.y - pos.y);  // origin bottom-left, like Shadertoy
    return float4(_Adjust(_Rainbow(saturate(mainImage(fragCoord).rgb), fragCoord)), 1.0);
}
)";

// Used when the configured wallpaper is missing or fails to load.
static const char kBuiltinShader[] = R"(
float4 mainImage(float2 fragCoord) {
    float2 uv = fragCoord / iResolution;
    float t = iTime * 0.08;
    float w = sin(uv.x * 3.0 + t * 2.0) * 0.08 + sin(uv.x * 7.0 - t * 3.0) * 0.03;
    float3 a = float3(0.05, 0.07, 0.16), b = float3(0.10, 0.32, 0.45), c = float3(0.42, 0.20, 0.55);
    float3 col = lerp(a, b, smoothstep(0.0, 1.0, uv.y + w));
    col += c * 0.35 * exp(-pow((uv.y - 0.5 - w) * 9.0, 2.0));
    return float4(col, 1.0);
}
)";

using PFN_D3DCompile = HRESULT(WINAPI*)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO*, ID3DInclude*, LPCSTR, LPCSTR,
                                        UINT, UINT, ID3DBlob**, ID3DBlob**);

struct ShaderAdjust {
    float speed = 1, hue = 0, saturation = 1, brightness = 1;
    Rainbow rainbow;
};

Rainbow Rainbow::For(const std::wstring& wallpaperPath) {
    std::wstring section = OverrideSection(wallpaperPath);
    wchar_t buf[32];
    GetPrivateProfileStringW(section.c_str(), L"rainbow", L"0", buf, ARRAYSIZE(buf), ConfigPath().c_str());
    Rainbow r;
    r.mode = std::clamp(_wtoi(buf + (buf[0] == L'"')), 0, 2);  // the settings window writes "1" with quotes
    r.speed = std::clamp(IniFloat(section, L"rainbow_speed", 1), 0.0f, 10.0f);
    return r;
}

void Rainbow::Fill(double seconds, float out[4]) const {
    if (!mode) {
        out[0] = out[1] = out[2] = out[3] = 0;
        return;
    }
    double turns = seconds * speed / 6.0;
    out[0] = (float)((turns - floor(turns)) * 6.283185307);
    out[1] = mode == 2 ? 6.2831853f : 0;
    out[2] = 1;
    out[3] = 0;
}

void Rainbow::Apply(const float rb[4], float c[3]) {
    if (rb[2] == 0) return;
    float a = rb[0] + rb[1] * 0.5f, ca = cosf(a), sa = sinf(a);
    const float k = 0.57735f;
    float kc = k * (c[0] + c[1] + c[2]);  // dot(k, c)
    float cross[3] = {k * (c[2] - c[1]), k * (c[0] - c[2]), k * (c[1] - c[0])};
    float r[3], hi = std::max({c[0], c[1], c[2]}), lo = std::min({c[0], c[1], c[2]});
    float grey = hi > 0 ? 1 - (hi - lo) / hi : 1;
    float luma = 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2];
    for (int i = 0; i < 3; i++) {
        r[i] = c[i] * ca + cross[i] * sa + k * kc * (1 - ca);
        float tint = (0.5f + 0.5f * cosf(a + 2.0944f * i)) * luma * 2;
        c[i] = std::clamp(r[i] + (tint - r[i]) * grey * 0.65f, 0.0f, 1.0f);
    }
}

static bool ReadFileBytes(const std::wstring& path, std::string& out);

// Compiled shaders are cached per user in %LOCALAPPDATA%\LiteWallpaper\shaders\<hash>.cso, keyed
// by the source, everything it #includes and the compiler target. The compiler (several MB, and up
// to seconds per shader) then only loads when a shader actually changed, which keeps both the
// wallpaper and the gallery's live previews light.
static uint64_t Fnv(uint64_t h, const std::string& s) {
    for (unsigned char c : s) h = (h ^ c) * 1099511628211ull;
    return h;
}

static uint64_t HashIncludes(uint64_t h, const std::string& code, const std::wstring& dir, int depth) {
    if (depth > 6) return h;
    for (size_t at = code.find("#include"); at != std::string::npos; at = code.find("#include", at + 8)) {
        size_t eol = code.find('\n', at), q1 = code.find('"', at), q2 = q1 == std::string::npos ? q1 : code.find('"', q1 + 1);
        if (q2 == std::string::npos || q2 > eol) continue;
        std::wstring file = dir + Utf8ToWide(code.substr(q1 + 1, q2 - q1 - 1));
        std::replace(file.begin(), file.end(), L'/', L'\\');
        std::string text;
        if (!ReadFileBytes(file, text)) continue;
        h = HashIncludes(Fnv(h, text), text, file.substr(0, file.find_last_of(L'\\') + 1), depth + 1);
    }
    return h;
}

static std::wstring ShaderCacheFile(const std::string& src, const std::wstring& shaderPath, const char* target) {
    static const std::wstring dir = [] {
        PWSTR p = nullptr;
        std::wstring d;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &p))) d = std::wstring(p) + L"\\LiteWallpaper";
        CoTaskMemFree(p);
        if (!d.empty()) {
            CreateDirectoryW(d.c_str(), nullptr);
            d += L"\\shaders";
            CreateDirectoryW(d.c_str(), nullptr);
        }
        return d;
    }();
    if (dir.empty()) return L"";
    uint64_t h = Fnv(14695981039346656037ull, std::string("d3dcompiler_47 O3 v1 ") + target);
    h = Fnv(h, src);
    if (!shaderPath.empty()) h = HashIncludes(h, src, shaderPath.substr(0, shaderPath.find_last_of(L"\\/") + 1), 0);
    wchar_t name[32];
    swprintf_s(name, L"\\%016llx.cso", (unsigned long long)h);
    return dir + name;
}

static void WriteFileAtomically(const std::wstring& path, const void* data, size_t size) {
    std::wstring tmp = path + L"." + std::to_wstring(GetCurrentThreadId()) + L".tmp";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    bool ok = WriteFile(f, data, (DWORD)size, &written, nullptr) && written == size;
    CloseHandle(f);
    if (!ok || !MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) DeleteFileW(tmp.c_str());
}

class ShaderSource final : public Source {
public:
    explicit ShaderSource(const ShaderAdjust& adjust = {}) : adjust_(adjust) {}

    // path: the shader file ("" for the built-in one), for finding the files it #includes.
    bool Compile(Gpu& gpu, const std::string& code, const std::string& name, const std::wstring& path, const Config& cfg,
                 std::wstring& err) {
        interval_ = 1.0 / cfg.fps;
        std::string src = kShaderHeader;
        src += "#line 1 \"" + name + "\"\n" + code + "\n" + kShaderFooter;
        const char* target = gpu.dev->GetFeatureLevel() >= D3D_FEATURE_LEVEL_11_0 ? "ps_5_0" : "ps_4_0";

        std::wstring cache = ShaderCacheFile(src, path, target);
        std::string cached;
        if (!cache.empty() && ReadFileBytes(cache, cached) && cached.size() > 4 &&
            SUCCEEDED(gpu.dev->CreatePixelShader(cached.data(), cached.size(), nullptr, &ps_)))
            return true;

        // Load the compiler only for the moment we need it; it's several MB we'd otherwise keep mapped.
        HMODULE dll = LoadLibraryW(L"d3dcompiler_47.dll");
        auto compile = dll ? (PFN_D3DCompile)GetProcAddress(dll, "D3DCompile") : nullptr;
        if (!compile) {
            err = L"d3dcompiler_47.dll not found";
            if (dll) FreeLibrary(dll);
            return false;
        }
        ComPtr<ID3DBlob> blob, errors;
        HRESULT hr = compile(src.data(), src.size(), name.c_str(), nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE, "PSMain",
                             target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &blob, &errors);
        if (SUCCEEDED(hr)) hr = gpu.dev->CreatePixelShader(blob->GetBufferPointer(), blob->GetBufferSize(), nullptr, &ps_);
        if (SUCCEEDED(hr) && !cache.empty()) WriteFileAtomically(cache, blob->GetBufferPointer(), blob->GetBufferSize());
        if (FAILED(hr)) {
            if (errors) {
                std::string e((const char*)errors->GetBufferPointer(), errors->GetBufferSize());
                err.assign(e.begin(), e.end());
                while (!err.empty() && (err.back() == L'\0' || iswspace(err.back()))) err.pop_back();
            } else {
                err = L"Shader compile failed";
            }
        }
        blob.Reset();
        errors.Reset();
        FreeLibrary(dll);
        return ps_ != nullptr;
    }

    bool LoadTexture(Gpu& gpu, int slot, const std::wstring& path, std::wstring& err) {
        hasTexture_[slot] = pic_[slot].Load(gpu, path, err);
        if (!hasTexture_[slot]) err = L"Texture " + path + L": " + err;
        return hasTexture_[slot];
    }
    void SetScale(float scale) { scale_ = scale; }

    double NextDue() const override { return next_; }
    float RenderScale(float configured) const override { return scale_ > 0 ? scale_ : configured; }
    void SetActive(bool active, double now) override {
        if (active) {
            next_ = now;
            for (auto& pic : pic_) pic.Restart(now);
        }
    }

    bool Update(double now, double animTime) override {
        for (int i = 0; i < kTextures; i++)
            if (hasTexture_[i]) pic_[i].Advance(now);
        if (lastAnim_ >= 0) time_ += (animTime - lastAnim_) * adjust_.speed;
        lastAnim_ = animTime;
        frame_ += 1;
        next_ += interval_;
        if (next_ < now) next_ = now + interval_;
        return true;
    }

    void Draw(Gpu& gpu, Screen& s) override {
        FrameConstants c{(float)s.bw, (float)s.bh, (float)time_, frame_, 1, 1, 0, 0,
                         {adjust_.hue * 3.14159265f / 180, adjust_.saturation, adjust_.brightness, 0}};
        adjust_.rainbow.Fill(lastAnim_, c.rainbow);
        SYSTEMTIME now;  // for clocks: the local date and time, like Shadertoy's iDate
        GetLocalTime(&now);
        c.date[0] = now.wYear;
        c.date[1] = now.wMonth;
        c.date[2] = now.wDay;
        c.date[3] = now.wHour * 3600.0f + now.wMinute * 60.0f + now.wSecond + now.wMilliseconds / 1000.0f;
        if (g_clockOverride >= 0) c.date[3] = (float)fmod(g_clockOverride, 86400.0);
        gpu.SetConstants(c);
        ID3D11ShaderResourceView* extra = hasTexture_[1] ? pic_[1].Srv(gpu) : nullptr;
        gpu.ctx->PSSetShaderResources(1, 1, &extra);  // DrawFullscreen binds slot 0
        gpu.DrawFullscreen(s, ps_.Get(), hasTexture_[0] ? pic_[0].Srv(gpu) : nullptr);
    }

private:
    ComPtr<ID3D11PixelShader> ps_;
    ShaderAdjust adjust_;
    static constexpr int kTextures = 2;
    Picture pic_[kTextures];
    bool hasTexture_[kTextures] = {};
    float scale_ = 0;  // from a "// scale:" line; 0 = use the configured scale
    double interval_ = 1.0 / 30, next_ = 0, time_ = 0, lastAnim_ = -1;
    float frame_ = 0;
};

// Shader options are comment lines such as "// texture: assets/photo.png" (bound as iChannel0,
// path relative to the shader; "// texture1:" binds iChannel1) and "// scale: 1" (this shader's
// render resolution).
static std::string ShaderOption(const std::string& code, const char* name) {
    std::string key = std::string("// ") + name + ":";
    size_t at = code.find(key);
    if (at == std::string::npos || (at > 0 && code[at - 1] != '\n')) return {};
    size_t b = code.find_first_not_of(" \t", at + key.size());
    size_t e = code.find_first_of("\r\n", at);
    if (b == std::string::npos || b >= e) return {};
    size_t last = code.find_last_not_of(" \t", e == std::string::npos ? std::string::npos : e - 1);
    return code.substr(b, last + 1 - b);
}

// A "// texture:" path: absolute, or relative to the shader's folder.
static std::wstring ShaderAssetPath(const std::wstring& shader, const std::string& rel) {
    std::wstring r(rel.begin(), rel.end());
    std::replace(r.begin(), r.end(), L'/', L'\\');
    if (r.size() > 1 && (r[1] == L':' || (r[0] == L'\\' && r[1] == L'\\'))) return r;
    return shader.substr(0, shader.find_last_of(L"\\/") + 1) + r;
}

static bool ReadFileBytes(const std::wstring& path, std::string& out) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size;
    GetFileSizeEx(f, &size);
    out.resize((size_t)std::min<LONGLONG>(size.QuadPart, 4 << 20));
    DWORD read = 0;
    BOOL ok = ReadFile(f, out.data(), (DWORD)out.size(), &read, nullptr);
    CloseHandle(f);
    out.resize(read);
    if (out.size() >= 3 && (unsigned char)out[0] == 0xEF && (unsigned char)out[1] == 0xBB && (unsigned char)out[2] == 0xBF)
        out.erase(0, 3);
    return ok != FALSE;
}

// ============================================================================================
// Images and animated GIFs (WIC). GIF frames are decoded one at a time onto a single canvas,
// so memory stays at one frame no matter how long the GIF is.
// ============================================================================================

static UINT ReadMetaUInt(IWICMetadataQueryReader* md, const wchar_t* name) {
    PROPVARIANT pv;
    PropVariantInit(&pv);
    UINT v = 0;
    if (md && SUCCEEDED(md->GetMetadataByName(name, &pv))) {
        if (pv.vt == VT_UI1) v = pv.bVal;
        else if (pv.vt == VT_UI2) v = pv.uiVal;
        else if (pv.vt == VT_UI4) v = pv.ulVal;
    }
    PropVariantClear(&pv);
    return v;
}

struct Picture::Impl {
    ComPtr<IWICBitmapDecoder> dec;
    ComPtr<ID3D11Texture2D> tex;
    ComPtr<ID3D11ShaderResourceView> srv;
    std::vector<uint32_t> canvas, backup, scratch;
    UINT frames = 1, cur = 0, cw = 0, ch = 0, prevDisposal = 0;
    RECT prevRect{};
    double delay = 0.1, nextAt = HUGE_VAL;
    bool dirty = false;

    bool CreateTexture(Gpu& gpu, bool immutable, std::wstring& err) {
        D3D11_TEXTURE2D_DESC td{};
        td.Width = cw;
        td.Height = ch;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = immutable ? D3D11_USAGE_IMMUTABLE : D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA init{canvas.data(), cw * 4, 0};
        HRESULT hr = gpu.dev->CreateTexture2D(&td, &init, &tex);
        if (SUCCEEDED(hr)) hr = gpu.dev->CreateShaderResourceView(tex.Get(), nullptr, &srv);
        if (FAILED(hr)) {
            err = L"Image too large for the GPU";
            return false;
        }
        dirty = false;
        return true;
    }

    void ClearRect(const RECT& r) {
        for (LONG y = std::max(0L, r.top); y < std::min((LONG)ch, r.bottom); ++y)
            for (LONG x = std::max(0L, r.left); x < std::min((LONG)cw, r.right); ++x) canvas[(size_t)y * cw + x] = 0;
    }

    void RenderGifFrame(UINT index) {
        if (index == 0) {
            std::fill(canvas.begin(), canvas.end(), 0u);
            prevDisposal = 0;
        } else if (prevDisposal == 2) {
            ClearRect(prevRect);
        } else if (prevDisposal == 3 && backup.size() == canvas.size()) {
            canvas = backup;
        }

        ComPtr<IWICBitmapFrameDecode> frame;
        if (FAILED(dec->GetFrame(index, &frame))) return;
        ComPtr<IWICMetadataQueryReader> md;
        frame->GetMetadataQueryReader(&md);
        UINT left = ReadMetaUInt(md.Get(), L"/imgdesc/Left"), top = ReadMetaUInt(md.Get(), L"/imgdesc/Top");
        UINT disposal = ReadMetaUInt(md.Get(), L"/grctlext/Disposal");
        UINT delayCs = ReadMetaUInt(md.Get(), L"/grctlext/Delay");
        delay = delayCs < 2 ? 0.1 : delayCs / 100.0;  // same rule browsers use for 0/10 ms delays

        UINT fw = 0, fh = 0;
        frame->GetSize(&fw, &fh);
        if (disposal == 3) backup = canvas;
        else if (!backup.empty()) std::vector<uint32_t>().swap(backup);

        ComPtr<IWICBitmapSource> conv;
        if (SUCCEEDED(WICConvertBitmapSource(GUID_WICPixelFormat32bppPBGRA, frame.Get(), &conv))) {
            scratch.resize((size_t)fw * fh);
            if (SUCCEEDED(conv->CopyPixels(nullptr, fw * 4, fw * fh * 4, (BYTE*)scratch.data()))) {
                for (UINT y = 0; y < fh && top + y < ch; ++y) {
                    const uint32_t* srcRow = &scratch[(size_t)y * fw];
                    uint32_t* dstRow = &canvas[(size_t)(top + y) * cw];
                    for (UINT x = 0; x < fw && left + x < cw; ++x)
                        if (srcRow[x] >> 24) dstRow[left + x] = srcRow[x];
                }
            }
        }
        prevDisposal = disposal;
        prevRect = {(LONG)left, (LONG)top, (LONG)(left + fw), (LONG)(top + fh)};
        dirty = true;
    }
};

Picture::Picture() : p_(std::make_unique<Impl>()) {}
Picture::~Picture() = default;
bool Picture::Animated() const { return p_->frames > 1; }
double Picture::NextDue() const { return p_->frames > 1 ? p_->nextAt : HUGE_VAL; }
UINT Picture::Width() const { return p_->cw; }
UINT Picture::Height() const { return p_->ch; }

void Picture::Restart(double now) {
    if (p_->frames > 1) p_->nextAt = now + p_->delay;
}

bool Picture::Advance(double now) {
    Impl& p = *p_;
    if (p.frames <= 1 || now < p.nextAt) return false;
    p.cur = (p.cur + 1) % p.frames;
    p.RenderGifFrame(p.cur);
    p.nextAt += p.delay;
    if (p.nextAt < now) p.nextAt = now + p.delay;
    return true;
}

ID3D11ShaderResourceView* Picture::Srv(Gpu& gpu) {
    Impl& p = *p_;
    if (p.dirty) {
        gpu.ctx->UpdateSubresource(p.tex.Get(), 0, nullptr, p.canvas.data(), p.cw * 4, 0);
        p.dirty = false;
    }
    return p.srv.Get();
}

static thread_local UINT t_maxTextureSide = 5120;

void SetTextureSizeLimit(UINT maxSide) { t_maxTextureSide = maxSide ? maxSide : 5120; }

bool Picture::Load(Gpu& gpu, const std::wstring& path, std::wstring& err) {
    Impl& p = *p_;
    ComPtr<IWICImagingFactory> wic;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
    if (SUCCEEDED(hr))
        hr = wic->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &p.dec);
    if (FAILED(hr)) {
        err = L"Unsupported or unreadable image";
        return false;
    }
    GUID format{};
    p.dec->GetContainerFormat(&format);
    p.dec->GetFrameCount(&p.frames);

    if (format == GUID_ContainerFormatGif && p.frames > 1) {
        ComPtr<IWICMetadataQueryReader> md;
        p.dec->GetMetadataQueryReader(&md);
        p.cw = ReadMetaUInt(md.Get(), L"/logscrdesc/Width");
        p.ch = ReadMetaUInt(md.Get(), L"/logscrdesc/Height");
        if (!p.cw || !p.ch) {
            ComPtr<IWICBitmapFrameDecode> f;
            p.dec->GetFrame(0, &f);
            f->GetSize(&p.cw, &p.ch);
        }
        p.canvas.assign((size_t)p.cw * p.ch, 0);
        p.cur = 0;
        p.RenderGifFrame(0);
        p.nextAt = HUGE_VAL;  // starts on Restart()
        return p.CreateTexture(gpu, false, err);
    }

    // Still image: decode once, upload, then drop every CPU-side copy.
    p.frames = 1;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(p.dec->GetFrame(0, &frame))) {
        err = L"Could not decode image";
        return false;
    }
    frame->GetSize(&p.cw, &p.ch);
    ComPtr<IWICBitmapSource> bmp = frame;
    const UINT maxSide = t_maxTextureSide;
    if (std::max(p.cw, p.ch) > maxSide) {
        double k = (double)maxSide / std::max(p.cw, p.ch);
        UINT nw = std::max(1u, (UINT)(p.cw * k)), nh = std::max(1u, (UINT)(p.ch * k));
        ComPtr<IWICBitmapScaler> scaler;
        wic->CreateBitmapScaler(&scaler);
        scaler->Initialize(frame.Get(), nw, nh, WICBitmapInterpolationModeFant);
        bmp = scaler;
        p.cw = nw;
        p.ch = nh;
    }
    ComPtr<IWICBitmapSource> conv;
    if (FAILED(WICConvertBitmapSource(GUID_WICPixelFormat32bppPBGRA, bmp.Get(), &conv))) {
        err = L"Could not convert image";
        return false;
    }
    p.canvas.resize((size_t)p.cw * p.ch);
    if (FAILED(conv->CopyPixels(nullptr, p.cw * 4, p.cw * p.ch * 4, (BYTE*)p.canvas.data()))) {
        err = L"Could not decode image";
        return false;
    }
    bool ok = p.CreateTexture(gpu, true, err);
    std::vector<uint32_t>().swap(p.canvas);
    p.dec.Reset();
    return ok;
}

class ImageSource final : public Source {
public:
    bool Load(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& err) {
        rainbow_ = Rainbow::For(path);
        interval_ = 1.0 / cfg.fps;
        return pic_.Load(gpu, path, err);
    }
    // A still picture draws once; with the rainbow on it redraws at the frame rate.
    double NextDue() const override { return rainbow_.On() ? std::min(pic_.NextDue(), next_) : pic_.NextDue(); }
    void SetActive(bool active, double now) override {
        if (active) {
            pic_.Restart(now);
            next_ = now;
        }
    }
    bool Update(double now, double) override {
        bool changed = pic_.Advance(now);
        now_ = now;
        if (rainbow_.On() && now >= next_) {
            next_ += interval_;
            if (next_ < now) next_ = now + interval_;
            changed = true;
        }
        return changed;
    }

    void Draw(Gpu& gpu, Screen& s) override {
        ID3D11ShaderResourceView* srv = pic_.Srv(gpu);
        FrameConstants c{(float)s.bw, (float)s.bh, 0, 0};
        FitTransform(s.cfg.fit, (float)pic_.Width(), (float)pic_.Height(), (float)s.bw, (float)s.bh, &c.uvScaleX);
        rainbow_.Fill(now_, c.rainbow);
        gpu.SetConstants(c);
        gpu.DrawFullscreen(s, gpu.psTex.Get(), srv);
    }

private:
    Picture pic_;
    Rainbow rainbow_;
    double interval_ = 1.0 / 30, next_ = 0, now_ = 0;
};

// ============================================================================================
// Video (Media Foundation media engine). Decoding runs on the GPU's video engine, frames are
// copied straight into each monitor's back buffer, and audio is switched off entirely.
// ============================================================================================

class VideoNotify final : public IMFMediaEngineNotify {
public:
    explicit VideoNotify(Source* owner) : owner_(owner) {}
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IMFMediaEngineNotify)) {
            *ppv = static_cast<IMFMediaEngineNotify*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&ref_); }
    STDMETHODIMP_(ULONG) Release() override {
        ULONG r = InterlockedDecrement(&ref_);
        if (!r) delete this;
        return r;
    }
    // Called on a Media Foundation thread; hand off to the UI thread.
    STDMETHODIMP EventNotify(DWORD event, DWORD_PTR, DWORD) override {
        if (event == MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA || event == MF_MEDIA_ENGINE_EVENT_ERROR)
            PostMessageW(g_mainWnd, WM_APP_VIDEO, event, (LPARAM)owner_);
        return S_OK;
    }

private:
    LONG ref_ = 1;
    Source* owner_;
};

class VideoSource final : public Source {
public:
    ~VideoSource() override {
        if (engine_) engine_->Shutdown();
        engineEx_.Reset();
        engine_.Reset();
        notify_.Reset();
        manager_.Reset();
        if (started_) MFShutdown();
    }

    bool Load(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& err) {
        interval_ = 1.0 / cfg.videoFps;
        if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
            err = L"Media Foundation is not available";
            return false;
        }
        started_ = true;
        UINT token = 0;
        HRESULT hr = MFCreateDXGIDeviceManager(&token, &manager_);
        if (SUCCEEDED(hr)) hr = manager_->ResetDevice(gpu.dev.Get(), token);
        ComPtr<IMFMediaEngineClassFactory> factory;
        if (SUCCEEDED(hr))
            hr = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
        ComPtr<IMFAttributes> attr;
        if (SUCCEEDED(hr)) hr = MFCreateAttributes(&attr, 3);
        if (SUCCEEDED(hr)) {
            notify_.Attach(new VideoNotify(this));
            attr->SetUnknown(MF_MEDIA_ENGINE_DXGI_MANAGER, manager_.Get());
            attr->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify_.Get());
            attr->SetUINT32(MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM);
            hr = factory->CreateInstance(0, attr.Get(), &engine_);
        }
        if (FAILED(hr)) {
            err = L"Could not start the video decoder";
            return false;
        }
        engine_.As(&engineEx_);
        engine_->SetMuted(TRUE);
        engine_->SetLoop(TRUE);
        engine_->SetAutoPlay(FALSE);
        BSTR url = SysAllocString(path.c_str());
        hr = engine_->SetSource(url);
        SysFreeString(url);
        if (FAILED(hr)) {
            err = L"Could not open video";
            return false;
        }
        return true;
    }

    double NextDue() const override { return next_; }

    void SetActive(bool active, double now) override {
        if (active) {
            engine_->Play();
            next_ = now;
        } else {
            engine_->Pause();
        }
    }

    bool Update(double now, double) override {
        next_ = now + interval_;
        LONGLONG pts;
        if (engine_->OnVideoStreamTick(&pts) == S_OK) {
            hasFrame_ = true;
            return true;
        }
        return false;
    }

    void Draw(Gpu& gpu, Screen& s) override {
        if (!hasFrame_ || !vw_ || !vh_) {
            const float black[4] = {0, 0, 0, 1};
            gpu.ctx->ClearRenderTargetView(s.rtv.Get(), black);
            return;
        }
        float t[4];
        FitTransform(s.cfg.fit, (float)vw_, (float)vh_, (float)s.bw, (float)s.bh, t);
        MFVideoNormalizedRect src{0, 0, 1, 1};
        RECT dst{0, 0, (LONG)s.bw, (LONG)s.bh};
        if (s.cfg.fit == Fit::Cover) {
            src = {t[2], t[3], t[2] + t[0], t[3] + t[1]};
        } else if (s.cfg.fit == Fit::Contain) {
            float w = s.bw / t[0], h = s.bh / t[1];
            dst = {(LONG)((s.bw - w) / 2), (LONG)((s.bh - h) / 2), (LONG)((s.bw + w) / 2), (LONG)((s.bh + h) / 2)};
        }
        MFARGB border{0, 0, 0, 255};
        engine_->TransferVideoFrame(s.backBuffer.Get(), &src, &dst, &border);
    }

    bool OnVideoEvent(DWORD event, std::wstring& error) override {
        if (event == MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA) {
            engine_->GetNativeVideoSize(&vw_, &vh_);
            DisableAudio();
            return true;
        }
        if (event == MF_MEDIA_ENGINE_EVENT_ERROR) {
            ComPtr<IMFMediaError> e;
            engine_->GetError(&e);
            wchar_t msg[128];
            swprintf_s(msg, L"Video playback error %u (0x%08X)", e ? e->GetErrorCode() : 0,
                       e ? (UINT)e->GetExtendedErrorCode() : 0);
            error = msg;
        }
        return false;
    }

private:
    // Deselecting the audio track means it's never decoded at all (muting still decodes it).
    void DisableAudio() {
        DWORD n = 0;
        if (!engineEx_ || FAILED(engineEx_->GetNumberOfStreams(&n))) return;
        bool changed = false;
        for (DWORD i = 0; i < n; ++i) {
            PROPVARIANT pv;
            PropVariantInit(&pv);
            if (SUCCEEDED(engineEx_->GetStreamAttribute(i, MF_MT_MAJOR_TYPE, &pv)) && pv.vt == VT_CLSID &&
                *pv.puuid == MFMediaType_Audio) {
                engineEx_->SetStreamSelection(i, FALSE);
                changed = true;
            }
            PropVariantClear(&pv);
        }
        if (changed) engineEx_->ApplyStreamSelections();
    }

    ComPtr<IMFDXGIDeviceManager> manager_;
    ComPtr<VideoNotify> notify_;
    ComPtr<IMFMediaEngine> engine_;
    ComPtr<IMFMediaEngineEx> engineEx_;
    DWORD vw_ = 0, vh_ = 0;
    double interval_ = 1.0 / 60, next_ = 0;
    bool started_ = false, hasFrame_ = false;
};

// ============================================================================================

static std::string Narrow(const std::wstring& w) {
    int n = WideCharToMultiByte(CP_ACP, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_ACP, 0, w.c_str(), -1, s.data(), n, nullptr, nullptr);
    for (auto& c : s)
        if (c == '\\') c = '/';
    return s;
}

std::unique_ptr<Source> CreateSource(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& error) {
    if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        error = L"File not found";
        return nullptr;
    }
    size_t dot = path.find_last_of(L'.');
    std::wstring ext = dot == std::wstring::npos ? L"" : ToLower(path.substr(dot));

    if (ext == L".hlsl" || ext == L".fx" || ext == L".shader") {
        std::string code;
        if (!ReadFileBytes(path, code)) {
            error = L"Could not read file";
            return nullptr;
        }
        std::wstring section = OverrideSection(path);
        ShaderAdjust adjust;
        adjust.speed = std::max(0.0f, IniFloat(section, L"speed", 1));
        adjust.hue = IniFloat(section, L"hue", 0);
        adjust.saturation = std::max(0.0f, IniFloat(section, L"saturation", 1));
        adjust.brightness = std::max(0.0f, IniFloat(section, L"brightness", 1));
        adjust.rainbow = Rainbow::For(path);
        auto s = std::make_unique<ShaderSource>(adjust);
        if (!s->Compile(gpu, code, Narrow(path), path, cfg, error)) return nullptr;
        const char* texOptions[] = {"texture", "texture1"};
        for (int i = 0; i < 2; i++) {
            std::string tex = ShaderOption(code, texOptions[i]);
            if (!tex.empty() && !s->LoadTexture(gpu, i, ShaderAssetPath(path, tex), error)) return nullptr;
        }
        std::string scale = ShaderOption(code, "scale");
        if (!scale.empty()) s->SetScale(std::clamp((float)atof(scale.c_str()), 0.1f, 1.0f));
        return s;
    }

    if (ext == L".json") return CreateParticleSource(gpu, path, cfg, error);

    static const wchar_t* videoExts[] = {L".mp4", L".m4v", L".mov", L".mkv", L".webm", L".avi", L".wmv"};
    for (auto v : videoExts) {
        if (ext == v) {
            auto s = std::make_unique<VideoSource>();
            if (!s->Load(gpu, path, cfg, error)) return nullptr;
            return s;
        }
    }

    auto s = std::make_unique<ImageSource>();
    if (!s->Load(gpu, path, cfg, error)) return nullptr;
    return s;
}

std::unique_ptr<Source> CreateBuiltinSource(Gpu& gpu, const Config& cfg, std::wstring& error) {
    auto s = std::make_unique<ShaderSource>();
    if (!s->Compile(gpu, kBuiltinShader, "builtin", L"", cfg, error)) return nullptr;
    return s;
}
