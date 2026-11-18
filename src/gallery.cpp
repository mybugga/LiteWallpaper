// Wallpaper gallery ("Showcase"): the selected wallpaper plays large at the top with its details and
// a "Set as wallpaper" button, over a blurred, live copy of itself; every wallpaper is a live tile in
// the grid below. Each preview runs the real wallpaper code into a small texture, and Direct2D draws
// everything else. Tiles scrolled far away drop their previews, and previews are created on
// background threads so compiling shaders never stalls the window.
//
// It runs as its own process (LiteWallpaper.exe --gallery-window): compiling dozens of shaders
// makes the graphics driver load its shader compiler and keep hundreds of MB for the life of the
// process. In a separate process all of that goes back to Windows when the gallery closes, and the
// wallpaper process stays small. Setting a wallpaper writes the settings file, which the running
// wallpaper watches.
#include "app.h"
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <dwmapi.h>
#include <dwrite_1.h>
#include <commdlg.h>
#include <windowsx.h>
#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace {

// Layout, in DIPs.
constexpr float kPad = 32, kHeroMaxW = 700, kTabsH = 44, kGap = 14, kMinTileW = 168, kNameH = 28, kRowGap = 12;
constexpr UINT WM_APP_PREVIEW = WM_APP + 20;  // a background preview finished loading
constexpr UINT_PTR kTimerFrame = 1;
constexpr size_t kHero = (size_t)-1;  // preview job for the big preview, not a tile
const wchar_t kClass[] = L"LiteWallpaper.Gallery";

D2D1_COLOR_F Rgb(UINT rgb, float a = 1) { return D2D1::ColorF(rgb, a); }
namespace Color {
const D2D1_COLOR_F Bg = Rgb(0x0E0E10), Text = Rgb(0xF2F2F4), Body = Rgb(0xB9B9C0), Dim = Rgb(0x8D8D95),
                   Name = Rgb(0xCFCFD4), Red = Rgb(0xFF3B3B), RedText = Rgb(0xFF5A5A), Field = Rgb(0x1C1C20),
                   Edge = Rgb(0xFFFFFF, 0.07f), EdgeHover = Rgb(0xFFFFFF, 0.45f), Ghost = Rgb(0xFFFFFF, 0.08f),
                   GhostHover = Rgb(0xFFFFFF, 0.14f), GhostEdge = Rgb(0xFFFFFF, 0.12f), Search = Rgb(0xFFFFFF, 0.07f);
}

struct Preview {
    std::unique_ptr<Source> src;
    Screen screen;
    ComPtr<ID3D11Texture2D> tex;
    ComPtr<ID2D1Bitmap1> bmp;
    ComPtr<ID2D1BitmapBrush1> brush;
};

struct Tile {
    WallpaperEntry entry;
    std::wstring path, key;  // resolved path; lower-case for comparing
    std::wstring name;       // "Astronaut blackhole"
    std::wstring desc;       // from a "// description:" line, if any
    bool particles = false;
    Preview pv;              // only while the tile is on or near the screen
    bool requested = false, failed = false;
};

struct Done {
    size_t index;
    std::wstring path;
    std::unique_ptr<Source> src;
};

struct {
    std::vector<std::thread> threads;
    std::mutex lock;
    std::condition_variable wake;
    std::deque<std::pair<size_t, std::wstring>> jobs;
    std::vector<Done> done;
    bool stop = false;
} W;

enum class Hit { None, Tile, Apply, Customize, Tab0, Tab1, Tab2, Open, Search };

struct {
    HWND wnd = nullptr;
    Gpu gpu;
    Config cfg;
    ComPtr<IDXGISwapChain1> swap;
    ComPtr<ID2D1Factory1> d2d;
    ComPtr<ID2D1Device> d2dDevice;
    ComPtr<ID2D1DeviceContext> dc;
    ComPtr<ID2D1Bitmap1> target;
    ComPtr<ID2D1SolidColorBrush> brush;
    ComPtr<ID2D1Effect> blur;
    ComPtr<ID2D1LinearGradientBrush> shade, redFill;
    ComPtr<IDWriteFactory> dw;
    ComPtr<IDWriteTextFormat> kind, title, body, statValue, statLabel, button, tabFont, tabOn, name, pill, icon;

    std::vector<Tile> tiles;
    std::vector<size_t> shown;  // tiles matching the tab and search, in order
    int tab = 0;                // 0 all, 1 shaders, 2 particles
    std::wstring search;

    size_t selected = 0;           // index into tiles
    Preview hero;                  // big live preview of the selected tile
    std::wstring heroPath;         // what hero shows (or is loading)
    bool heroRequested = false;

    float dpi = 96, w = 0, h = 0;  // client size in DIPs
    float heroW = 0, heroH = 0, gridTop = 0, tabsTop = 0, contentH = 0;
    int cols = 1;
    float tileW = 0, tileH = 0;
    float scroll = 0, scrollTarget = 0;
    Hit hover = Hit::None;
    int hoverTile = -1;  // index into shown
    bool tracking = false;
    D2D1_RECT_F apply{}, customize{}, tabs[3]{}, open{}, searchBox{};
    std::wstring current;  // lower-case resolved source in use
    std::wstring iconFamily;
    double start = 0;
} G;

double Now() {
    static const double freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return (double)f.QuadPart;
    }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return c.QuadPart / freq;
}

// "astronaut_blackhole" -> "Astronaut blackhole"
std::wstring Pretty(std::wstring s) {
    std::replace(s.begin(), s.end(), L'_', L' ');
    std::replace(s.begin(), s.end(), L'-', L' ');
    if (!s.empty()) s[0] = (wchar_t)towupper(s[0]);
    return s;
}

float Px(float dip) { return dip * G.dpi / 96.0f; }

bool In(const D2D1_RECT_F& r, float x, float y) { return x >= r.left && x < r.right && y >= r.top && y < r.bottom; }

// What a shader shows, for the details beside the big preview: a "// description: ..." line if it
// has one, otherwise the comment at its top ("// Skull: a skull wreathed in smoke, ..."), without the
// name, technical notes or option lines, cut to the first sentence or two.
std::wstring FileDescription(const std::wstring& path) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return L"";
    char buf[4096];
    DWORD got = 0;
    ReadFile(f, buf, sizeof(buf) - 1, &got, nullptr);
    CloseHandle(f);
    std::string text(buf, got);
    if (text.size() >= 3 && (unsigned char)text[0] == 0xEF) text.erase(0, 3);  // UTF-8 BOM

    std::string d;
    size_t at = text.find("// description:");
    if (at != std::string::npos) {
        size_t b = at + 15, e = text.find_first_of("\r\n", b);
        d = text.substr(b, e == std::string::npos ? std::string::npos : e - b);
    } else {
        size_t pos = 0;
        while (pos < text.size() && text.compare(pos, 2, "//") == 0) {
            size_t e = text.find('\n', pos);
            std::string line = text.substr(pos + 2, (e == std::string::npos ? text.size() : e) - pos - 2);
            while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
            line.erase(0, line.find_first_not_of(' '));
            for (const char* option : {"texture", "texture1", "scale", "Available"})
                if (line.rfind(std::string(option) + ":", 0) == 0) line.clear();
            if (line.empty()) break;
            d += (d.empty() ? "" : " ") + line;
            if (e == std::string::npos) break;
            pos = e + 1;
        }
        size_t colon = d.find(": ");
        if (colon != std::string::npos && colon < 32) d.erase(0, colon + 2);  // "Skull: ..."
    }
    for (size_t p; (p = d.find(" (see ")) != std::string::npos;) {  // "(see planet.hlsli)"
        size_t e = d.find(')', p);
        d.erase(p, e == std::string::npos ? std::string::npos : e - p + 1);
    }
    d.erase(0, d.find_first_not_of(" \t"));
    // Whole sentences, about four lines' worth.
    size_t cut = std::string::npos;
    for (size_t p = d.find(". "); p != std::string::npos && p < 230; p = d.find(". ", p + 1)) cut = p + 1;
    if (d.size() > 230) d = cut != std::string::npos ? d.substr(0, cut) : d.substr(0, 227) + "...";
    if (!d.empty()) d[0] = (char)toupper((unsigned char)d[0]);
    return Utf8ToWide(d);
}

// ---------------------------------------------------------------------------------------------
// Background loading

void WorkerMain() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    for (;;) {
        std::pair<size_t, std::wstring> job;
        {
            std::unique_lock<std::mutex> g(W.lock);
            W.wake.wait(g, [] { return W.stop || !W.jobs.empty(); });
            if (W.stop) break;
            job = std::move(W.jobs.front());
            W.jobs.pop_front();
        }
        // Small previews don't need full-size images; the big one gets a bit more.
        SetTextureSizeLimit(job.first == kHero ? 1280 : 384);
        std::wstring err;
        auto src = CreateSource(G.gpu, job.second, G.cfg, err);
        if (!src) Log(L"Gallery preview %s: %s", job.second.c_str(), err.c_str());
        {
            std::lock_guard<std::mutex> g(W.lock);
            W.done.push_back({job.first, job.second, std::move(src)});
        }
        PostMessageW(G.wnd, WM_APP_PREVIEW, 0, 0);
    }
    CoUninitialize();
}

void Request(size_t index, const std::wstring& path) {
    {
        std::lock_guard<std::mutex> g(W.lock);
        W.jobs.emplace_front(index, path);  // the newest request is what's on screen now
    }
    W.wake.notify_one();
}

void ReleasePreview(Preview& p) {
    p.src.reset();
    p.brush.Reset();
    p.bmp.Reset();
    p.screen.rtv.Reset();
    p.tex.Reset();
    p.screen.bw = p.screen.bh = 0;
}

void TakeFinished() {
    std::vector<Done> done;
    {
        std::lock_guard<std::mutex> g(W.lock);
        done.swap(W.done);
    }
    double now = Now();
    for (auto& d : done) {
        Preview* p;
        if (d.index == kHero) {
            if (d.path != G.heroPath) continue;  // the selection moved on while it loaded
            G.heroRequested = false;
            p = &G.hero;
        } else {
            Tile& t = G.tiles[d.index];
            t.requested = false;
            if (!d.src) t.failed = true;
            p = &t.pv;
        }
        if (!d.src) continue;
        p->src = std::move(d.src);
        p->src->active = true;
        p->src->SetActive(true, now);
        p->screen.needsDraw = true;
    }
}

void StopWorkers() {
    {
        std::lock_guard<std::mutex> g(W.lock);
        W.stop = true;
        W.jobs.clear();
    }
    W.wake.notify_all();
    for (auto& t : W.threads)
        if (t.joinable()) t.join();
    W.threads.clear();
    W.done.clear();
    W.stop = false;
}

// ---------------------------------------------------------------------------------------------
// Previews

// The preview's render target at `w` x `h` DIPs. Particle simulations are sized when they start,
// so one that changes size starts again.
bool EnsureTarget(Preview& p, float wDip, float hDip, bool particles, const std::function<void()>& restart) {
    UINT w = std::max(1, (int)std::lround(Px(wDip))), h = std::max(1, (int)std::lround(Px(hDip)));
    if (p.tex && p.screen.bw == w && p.screen.bh == h) return true;
    if (particles && p.src && p.tex) {
        p.src.reset();
        restart();
    }
    p.brush.Reset();
    p.bmp.Reset();
    p.screen.rtv.Reset();
    p.tex.Reset();
    D3D11_TEXTURE2D_DESC td{};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ComPtr<IDXGISurface> surface;
    if (FAILED(G.gpu.dev->CreateTexture2D(&td, nullptr, &p.tex)) ||
        FAILED(G.gpu.dev->CreateRenderTargetView(p.tex.Get(), nullptr, &p.screen.rtv)) || FAILED(p.tex.As(&surface)))
        return false;
    D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), G.dpi, G.dpi);
    if (FAILED(G.dc->CreateBitmapFromDxgiSurface(surface.Get(), &bp, &p.bmp)) ||
        FAILED(G.dc->CreateBitmapBrush(p.bmp.Get(), &p.brush)))
        return false;
    p.screen.bw = w;
    p.screen.bh = h;
    p.screen.cfg.fit = Fit::Cover;
    p.screen.previewScale = w / 1600.0f;  // particles look like a full screen seen from afar
    p.screen.needsDraw = true;
    return true;
}

void Step(Preview& p, double now) {
    if (!p.src || !p.screen.rtv) return;
    if (now >= p.src->NextDue() || p.screen.needsDraw) {
        p.src->Update(now, now - G.start);
        p.src->Draw(G.gpu, p.screen);
        p.screen.needsDraw = false;
    }
}

// ---------------------------------------------------------------------------------------------
// Layout and selection

D2D1_RECT_F HeroRect() {
    float top = 34 - G.scroll;
    return D2D1::RectF(kPad, top, kPad + G.heroW, top + G.heroH);
}

D2D1_RECT_F TileRect(size_t k) {
    float x = kPad + (k % G.cols) * (G.tileW + kGap);
    float y = G.gridTop + (k / G.cols) * (G.tileH + kNameH + kRowGap) - G.scroll;
    return D2D1::RectF(x, y, x + G.tileW, y + G.tileH);
}

float TabsY() { return std::max(0.0f, G.tabsTop - G.scroll); }  // sticks to the top once scrolled up to it

float MaxScroll() { return std::max(0.0f, G.contentH - G.h); }

void Layout() {
    RECT rc;
    GetClientRect(G.wnd, &rc);
    G.w = rc.right * 96.0f / G.dpi;
    G.h = rc.bottom * 96.0f / G.dpi;
    G.heroW = std::min(kHeroMaxW, std::round((G.w - 2 * kPad) * 0.58f));
    G.heroH = std::round(G.heroW * 9 / 16);
    G.tabsTop = 34 + G.heroH + 22;
    G.gridTop = G.tabsTop + kTabsH + 10;
    G.cols = std::max(2, (int)((G.w - 2 * kPad + kGap) / (kMinTileW + kGap)));
    G.tileW = (G.w - 2 * kPad - (G.cols - 1) * kGap) / G.cols;
    G.tileH = std::round(G.tileW * 9 / 16);
    size_t rows = (G.shown.size() + G.cols - 1) / G.cols;
    G.contentH = G.gridTop + rows * (G.tileH + kNameH + kRowGap) + kPad;
    G.scrollTarget = std::clamp(G.scrollTarget, 0.0f, MaxScroll());
    G.scroll = std::clamp(G.scroll, 0.0f, MaxScroll());
}

void Refilter() {
    std::wstring q = ToLower(G.search);
    G.shown.clear();
    for (size_t i = 0; i < G.tiles.size(); ++i) {
        const Tile& t = G.tiles[i];
        if (G.tab == 1 && t.particles) continue;
        if (G.tab == 2 && !t.particles) continue;
        if (!q.empty() && ToLower(t.name).find(q) == std::wstring::npos) continue;
        G.shown.push_back(i);
    }
    G.hoverTile = -1;
    Layout();
}

void ScrollIntoView(size_t tile) {
    auto it = std::find(G.shown.begin(), G.shown.end(), tile);
    if (it == G.shown.end()) return;
    D2D1_RECT_F r = TileRect(it - G.shown.begin());
    float top = r.top + G.scroll, bottom = r.bottom + kNameH + G.scroll;
    float view0 = G.scrollTarget + kTabsH + 10, view1 = G.scrollTarget + G.h;
    if (top < view0) G.scrollTarget = top - kTabsH - 10;
    else if (bottom > view1) G.scrollTarget = bottom - G.h + kPad;
    G.scrollTarget = std::clamp(G.scrollTarget, 0.0f, MaxScroll());
}

void Select(size_t tile) {
    if (tile >= G.tiles.size()) return;
    G.selected = tile;
    if (G.heroPath != G.tiles[tile].path) {
        ReleasePreview(G.hero);
        G.heroPath = G.tiles[tile].path;
        G.heroRequested = false;
    }
}

void SetAsWallpaper() {
    const Tile& t = G.tiles[G.selected];
    WritePrivateProfileStringW(L"default", L"source", t.entry.rel.c_str(), ConfigPath().c_str());  // the wallpaper reloads
    G.current = t.key;
}

void RunSelf(const wchar_t* args) {
    wchar_t exe[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
    std::wstring cmd = L"\"" + std::wstring(exe, n) + L"\" " + args;
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    AllowSetForegroundWindow(ASFW_ANY);
    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

void OpenFile() {
    wchar_t file[MAX_PATH * 2] = L"";
    OPENFILENAMEW ofn{sizeof(ofn)};
    ofn.hwndOwner = G.wnd;
    ofn.lpstrFilter = L"Wallpapers\0*.hlsl;*.json;*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.wmv;*.gif;*.png;*.jpg;*.jpeg;*.bmp\0All files\0*.*\0";
    ofn.lpstrFile = file;
    ofn.nMaxFile = ARRAYSIZE(file);
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) return;
    WritePrivateProfileStringW(L"default", L"source", file, ConfigPath().c_str());
    G.current = ToLower(file);
}

// ---------------------------------------------------------------------------------------------
// Drawing helpers

ComPtr<IDWriteTextFormat> Font(const wchar_t* family, float size, DWRITE_FONT_WEIGHT weight, bool wrap = false,
                               DWRITE_TEXT_ALIGNMENT align = DWRITE_TEXT_ALIGNMENT_LEADING) {
    ComPtr<IDWriteTextFormat> f;
    G.dw->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"", &f);
    if (!f) return f;
    f->SetTextAlignment(align);
    f->SetParagraphAlignment(wrap ? DWRITE_PARAGRAPH_ALIGNMENT_NEAR : DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    if (wrap) {
        f->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, size * 1.5f, size * 1.15f);
    } else {
        f->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        G.dw->CreateEllipsisTrimmingSign(f.Get(), &ellipsis);
        f->SetTrimming(&trim, ellipsis.Get());
    }
    return f;
}

bool HasFamily(const wchar_t* family) {
    ComPtr<IDWriteFontCollection> fonts;
    UINT32 index;
    BOOL exists = FALSE;
    return SUCCEEDED(G.dw->GetSystemFontCollection(&fonts)) && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
}

float TextWidth(IDWriteTextFormat* f, const std::wstring& s) {
    ComPtr<IDWriteTextLayout> layout;
    DWRITE_TEXT_METRICS m{};
    if (SUCCEEDED(G.dw->CreateTextLayout(s.c_str(), (UINT32)s.size(), f, 4000, 200, &layout))) layout->GetMetrics(&m);
    return m.widthIncludingTrailingWhitespace;
}

void Text(const std::wstring& s, IDWriteTextFormat* f, D2D1_RECT_F r, D2D1_COLOR_F c) {
    G.brush->SetColor(c);
    G.dc->DrawTextW(s.c_str(), (UINT32)s.size(), f, r, G.brush.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

// Text with extra letter spacing (the small capitals above the title).
void SpacedText(const std::wstring& s, IDWriteTextFormat* f, float x, float y, float spacing, D2D1_COLOR_F c) {
    ComPtr<IDWriteTextLayout> layout;
    ComPtr<IDWriteTextLayout1> layout1;
    if (FAILED(G.dw->CreateTextLayout(s.c_str(), (UINT32)s.size(), f, 2000, 30, &layout))) return;
    if (SUCCEEDED(layout.As(&layout1))) layout1->SetCharacterSpacing(0, spacing, 0, {0, (UINT32)s.size()});
    G.brush->SetColor(c);
    G.dc->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), G.brush.Get());
}

void Fill(D2D1_RECT_F r, float radius, D2D1_COLOR_F c) {
    G.brush->SetColor(c);
    G.dc->FillRoundedRectangle(D2D1::RoundedRect(r, radius, radius), G.brush.Get());
}

void Stroke(D2D1_RECT_F r, float radius, D2D1_COLOR_F c, float width) {
    G.brush->SetColor(c);
    G.dc->DrawRoundedRectangle(D2D1::RoundedRect(r, radius, radius), G.brush.Get(), width);
}

D2D1_RECT_F Inflate(D2D1_RECT_F r, float d) { return D2D1::RectF(r.left - d, r.top - d, r.right + d, r.bottom + d); }

// A preview's live image, with rounded corners.
bool DrawPreview(Preview& p, D2D1_RECT_F r, float radius) {
    if (!p.src || !p.brush) return false;
    p.brush->SetTransform(D2D1::Matrix3x2F::Translation(r.left, r.top));
    G.dc->FillRoundedRectangle(D2D1::RoundedRect(r, radius, radius), p.brush.Get());
    return true;
}

// A soft shadow without an effect: a few transparent layers growing outwards.
void Shadow(D2D1_RECT_F r, float radius) {
    for (int i = 1; i <= 7; ++i) {
        D2D1_RECT_F s = Inflate(r, i * 3.0f);
        s.top += i * 2.5f;
        s.bottom += i * 4.5f;
        Fill(s, radius + i * 3.0f, Rgb(0x000000, 0.07f));
    }
}

void Dot(float x, float y, float r, D2D1_COLOR_F c) {
    G.brush->SetColor(c);
    G.dc->FillEllipse(D2D1::Ellipse(D2D1::Point2F(x, y), r, r), G.brush.Get());
}

// ---------------------------------------------------------------------------------------------
// Painting

void PaintBackground() {
    // A blurred copy of the selected wallpaper fills the window, darkened towards the bottom.
    Preview& src = G.hero.bmp && G.hero.src ? G.hero : G.tiles[G.selected].pv;
    if (src.bmp && src.src && G.blur) {
        D2D1_SIZE_F sz = src.bmp->GetSize();
        float s = std::max(G.w / sz.width, G.h / sz.height) * 1.15f;
        G.blur->SetInput(0, src.bmp.Get());
        G.dc->SetTransform(D2D1::Matrix3x2F::Scale(s, s) *
                           D2D1::Matrix3x2F::Translation((G.w - sz.width * s) / 2, (G.h - sz.height * s) / 2));
        G.dc->DrawImage(G.blur.Get());
        G.dc->SetTransform(D2D1::Matrix3x2F::Identity());
    }
    G.shade->SetStartPoint(D2D1::Point2F(0, 0));
    G.shade->SetEndPoint(D2D1::Point2F(0, G.h));
    G.dc->FillRectangle(D2D1::RectF(0, 0, G.w, G.h), G.shade.Get());
}

void PaintHero() {
    D2D1_RECT_F r = HeroRect();
    if (r.bottom < 0) return;
    Tile& t = G.tiles[G.selected];
    Shadow(r, 18);
    if (!DrawPreview(G.hero, r, 18) && !DrawPreview(t.pv, r, 18)) Fill(r, 18, Color::Field);
    Stroke(r, 18, Color::Edge, 1);

    // "Live preview" badge.
    float bw = TextWidth(G.pill.Get(), L"Live preview") + 34;
    D2D1_RECT_F badge{r.left + 16, r.top + 16, r.left + 16 + bw, r.top + 42};
    Fill(badge, 13, Rgb(0x000000, 0.5f));
    Dot(badge.left + 14, (badge.top + badge.bottom) / 2, 6, Rgb(0xFF3B3B, 0.25f));
    Dot(badge.left + 14, (badge.top + badge.bottom) / 2, 3.5f, Color::Red);
    Text(L"Live preview", G.pill.Get(), D2D1::RectF(badge.left + 24, badge.top, badge.right, badge.bottom), Color::Text);

    // Details beside it.
    float x = r.right + 32, right = G.w - kPad, y = r.top + 6;
    SpacedText(t.particles ? L"PARTICLES \x00B7 INTERACTIVE" : L"SHADER \x00B7 ANIMATED", G.kind.Get(), x, y, 1.8f, Color::RedText);
    Text(t.name, G.title.Get(), D2D1::RectF(x, y + 22, right, y + 82), Color::Text);
    std::wstring desc = t.desc;
    if (desc.empty())
        desc = t.particles ? L"A particles.js effect, simulated natively. The particles react to your mouse on the desktop, "
                             L"and it all stops while a game is fullscreen."
                           : L"Drawn live on your graphics card, with almost no cost. It stops completely while a game or "
                             L"fullscreen app is running.";
    Text(desc, G.body.Get(), D2D1::RectF(x, y + 92, std::min(right, x + 440), y + 182), Color::Body);

    struct Stat { std::wstring value, label; };
    Stat stats[] = {{std::to_wstring(G.cfg.fps) + L" fps", L"Frame rate"},
                    {t.particles ? L"Particles" : L"Shader", L"Type"},
                    {G.cfg.pauseOnFullscreen ? L"On" : L"Off", L"Pauses for games"}};
    float sx = x;
    for (auto& s : stats) {
        float sw = std::max(TextWidth(G.statValue.Get(), s.value), TextWidth(G.statLabel.Get(), s.label));
        Text(s.value, G.statValue.Get(), D2D1::RectF(sx, y + 192, sx + sw + 4, y + 216), Color::Text);
        Text(s.label, G.statLabel.Get(), D2D1::RectF(sx, y + 216, sx + sw + 4, y + 234), Color::Dim);
        sx += sw + 26;
    }

    // Buttons, along the bottom of the preview.
    bool inUse = t.key == G.current;
    std::wstring applyText = inUse ? L"\x2713  In use" : L"Set as wallpaper";
    float aw = TextWidth(G.button.Get(), applyText) + 52, cw = TextWidth(G.button.Get(), L"Customize") + 52;
    G.apply = D2D1::RectF(x, r.bottom - 44, x + aw, r.bottom);
    G.customize = D2D1::RectF(G.apply.right + 10, r.bottom - 44, G.apply.right + 10 + cw, r.bottom);
    if (inUse) {
        Fill(G.apply, 12, Color::Ghost);
        Stroke(G.apply, 12, Rgb(0xFF3B3B, 0.6f), 1);
    } else {
        for (int i = 3; i >= 1; --i) Fill(Inflate(G.apply, i * 3.0f), 12 + i * 3.0f, Rgb(0xE61E1E, 0.07f));  // glow
        G.redFill->SetStartPoint(D2D1::Point2F(0, G.apply.top));
        G.redFill->SetEndPoint(D2D1::Point2F(0, G.apply.bottom));
        G.dc->FillRoundedRectangle(D2D1::RoundedRect(G.apply, 12, 12), G.redFill.Get());
        if (G.hover == Hit::Apply) Fill(G.apply, 12, Rgb(0xFFFFFF, 0.1f));
    }
    Text(applyText, G.button.Get(), G.apply, Color::Text);
    Fill(G.customize, 12, G.hover == Hit::Customize ? Color::GhostHover : Color::Ghost);
    Stroke(G.customize, 12, Color::GhostEdge, 1);
    Text(L"Customize", G.button.Get(), G.customize, Color::Text);
}

void PaintTabs() {
    float y = TabsY();
    if (y <= 0.5f) {  // stuck to the top: give it a backdrop
        G.brush->SetColor(Rgb(0x0E0E10, 0.92f));
        G.dc->FillRectangle(D2D1::RectF(0, 0, G.w, kTabsH + 8), G.brush.Get());
        G.brush->SetColor(Rgb(0xFFFFFF, 0.06f));
        G.dc->FillRectangle(D2D1::RectF(0, kTabsH + 7, G.w, kTabsH + 8), G.brush.Get());
    }
    size_t shaders = std::count_if(G.tiles.begin(), G.tiles.end(), [](const Tile& t) { return !t.particles; });
    std::wstring labels[3] = {L"All " + std::to_wstring(G.tiles.size()), L"Shaders " + std::to_wstring(shaders),
                              L"Particles " + std::to_wstring(G.tiles.size() - shaders)};
    float x = kPad;
    for (int i = 0; i < 3; ++i) {
        bool on = G.tab == i;
        float tw = TextWidth(on ? G.tabOn.Get() : G.tabFont.Get(), labels[i]);
        G.tabs[i] = D2D1::RectF(x - 6, y + 4, x + tw + 6, y + kTabsH - 4);
        Hit me = (Hit)((int)Hit::Tab0 + i);
        Text(labels[i], on ? G.tabOn.Get() : G.tabFont.Get(), D2D1::RectF(x, y, x + tw + 2, y + kTabsH - 6),
             on || G.hover == me ? Color::Text : Rgb(0x9A9AA2));
        if (on) Fill(D2D1::RectF(x, y + kTabsH - 8, x + tw, y + kTabsH - 5), 1.5f, Color::Red);
        x += tw + 26;
    }
    std::wstring openText = L"Open file\x2026";
    float ow = TextWidth(G.tabFont.Get(), openText);
    G.open = D2D1::RectF(x - 6, y + 4, x + ow + 6, y + kTabsH - 4);
    Text(openText, G.tabFont.Get(), D2D1::RectF(x, y, x + ow + 2, y + kTabsH - 6), G.hover == Hit::Open ? Color::Text : Rgb(0x9A9AA2));

    G.searchBox = D2D1::RectF(G.w - kPad - 260, y + 4, G.w - kPad, y + kTabsH - 6);
    Fill(G.searchBox, 10, G.search.empty() ? Color::Search : Rgb(0xFFFFFF, 0.1f));
    if (!G.search.empty()) Stroke(G.searchBox, 10, Rgb(0xFF3B3B, 0.5f), 1);
    Text(L"\xE721", G.icon.Get(), D2D1::RectF(G.searchBox.left + 12, G.searchBox.top, G.searchBox.left + 30, G.searchBox.bottom), Color::Dim);
    bool caret = G.search.empty() || fmod(Now(), 1.0) < 0.55;
    Text(G.search.empty() ? L"Type to search wallpapers" : G.search + (caret ? L"|" : L" "), G.tabFont.Get(),
         D2D1::RectF(G.searchBox.left + 36, G.searchBox.top, G.searchBox.right - 10, G.searchBox.bottom),
         G.search.empty() ? Color::Dim : Color::Text);
}

void PaintGrid() {
    float clipTop = TabsY() + kTabsH + 8;
    G.dc->PushAxisAlignedClip(D2D1::RectF(0, clipTop, G.w, G.h), D2D1_ANTIALIAS_MODE_ALIASED);
    for (size_t k = 0; k < G.shown.size(); ++k) {
        D2D1_RECT_F r = TileRect(k);
        if (r.bottom + kNameH < clipTop || r.top > G.h) continue;
        Tile& t = G.tiles[G.shown[k]];
        bool sel = G.shown[k] == G.selected, hover = (int)k == G.hoverTile, inUse = t.key == G.current;
        if (sel) {
            for (int i = 3; i >= 1; --i) Stroke(Inflate(r, 1.5f + i * 2.5f), 10 + i * 2.5f, Rgb(0xFF3B3B, 0.10f), 3);  // glow
        }
        if (!DrawPreview(t.pv, r, 10)) Fill(r, 10, Color::Field);
        if (sel) Stroke(Inflate(r, 1), 11, Color::Red, 2);
        else Stroke(r, 10, hover ? Color::EdgeHover : Color::Edge, hover ? 1.5f : 1);
        if (inUse) {
            float pw = TextWidth(G.pill.Get(), L"In use") + 28;
            D2D1_RECT_F p{r.left + 8, r.top + 8, r.left + 8 + pw, r.top + 30};
            Fill(p, 11, Rgb(0x000000, 0.6f));
            Dot(p.left + 12, (p.top + p.bottom) / 2, 3.5f, Color::Red);
            Text(L"In use", G.pill.Get(), D2D1::RectF(p.left + 20, p.top, p.right, p.bottom), Color::Text);
        }
        Text(t.name, G.name.Get(), D2D1::RectF(r.left, r.bottom + 6, r.right, r.bottom + 26), sel || hover ? Color::Text : Color::Name);
    }
    if (G.shown.empty())
        Text(L"No wallpapers match \x201C" + G.search + L"\x201D", G.body.Get(),
             D2D1::RectF(kPad, G.gridTop - G.scroll + 10, G.w - kPad, G.gridTop - G.scroll + 40), Color::Dim);
    G.dc->PopAxisAlignedClip();

    if (G.contentH > G.h) {  // scroll bar
        float barH = std::max(40.0f, G.h * G.h / G.contentH);
        float y = (G.h - barH) * (G.scroll / MaxScroll());
        Fill(D2D1::RectF(G.w - 8, y + 4, G.w - 4, y + barH - 4), 2, Rgb(0xFFFFFF, 0.2f));
    }
}

void Paint() {
    if (!G.target || G.tiles.empty()) return;
    G.dc->BeginDraw();
    G.dc->Clear(Color::Bg);
    PaintBackground();
    PaintHero();
    PaintGrid();
    PaintTabs();
    HRESULT hr = G.dc->EndDraw();
    if (SUCCEEDED(hr)) hr = G.swap->Present(1, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET || hr == D2DERR_RECREATE_TARGET) {
        Log(L"Gallery: graphics device lost, closing it");
        DestroyWindow(G.wnd);
    }
}

// One step: smooth scrolling, previews that are due, then the window.
void Frame() {
    TakeFinished();
    float diff = G.scrollTarget - G.scroll;
    G.scroll = std::abs(diff) < 0.5f ? G.scrollTarget : G.scroll + diff * 0.3f;

    double now = Now();
    G.gpu.ctx->ClearState();  // Direct2D shares this context

    // The big preview.
    Tile& sel = G.tiles[G.selected];
    if (HeroRect().bottom > 0 && !G.heroPath.empty()) {
        if (!G.hero.src && !G.heroRequested) {
            G.heroRequested = true;
            Request(kHero, G.heroPath);
        }
        if (G.hero.src &&
            EnsureTarget(G.hero, G.heroW, G.heroH, sel.particles, [] { G.heroRequested = true; Request(kHero, G.heroPath); }))
            Step(G.hero, now);
    }

    // The tiles on or near the screen.
    std::vector<char> keep(G.tiles.size(), 0);
    keep[G.selected] = 1;  // its tile stands in for the big preview while that loads
    size_t newRequests = 0;
    for (size_t k = 0; k < G.shown.size(); ++k) {
        D2D1_RECT_F r = TileRect(k);
        bool visible = r.bottom > TabsY() + kTabsH && r.top < G.h;
        float row = G.tileH + kNameH + kRowGap;  // keep one row either side, ready for scrolling
        bool nearby = r.bottom > TabsY() + kTabsH - row && r.top < G.h + row;
        size_t i = G.shown[k];
        Tile& t = G.tiles[i];
        if (!nearby) continue;
        keep[i] = 1;
        if (!visible && i != G.selected) continue;
        if (!t.pv.src) {
            if (!t.requested && !t.failed && newRequests < 8) {
                t.requested = true;
                Request(i, t.path);
                ++newRequests;
            }
            continue;
        }
        if (EnsureTarget(t.pv, G.tileW, G.tileH, t.particles, [&t, i] { t.requested = true; Request(i, t.path); }))
            Step(t.pv, now);
    }
    if (!sel.pv.src && !sel.requested && !sel.failed) {
        sel.requested = true;
        Request(G.selected, sel.path);
    }
    for (size_t i = 0; i < G.tiles.size(); ++i)
        if (!keep[i] && (G.tiles[i].pv.src || G.tiles[i].pv.tex)) ReleasePreview(G.tiles[i].pv);
    // Scrolled past before it loaded: don't make what's on screen wait behind it.
    {
        std::lock_guard<std::mutex> g(W.lock);
        for (auto it = W.jobs.begin(); it != W.jobs.end();) {
            if (it->first != kHero && !keep[it->first]) {
                G.tiles[it->first].requested = false;
                it = W.jobs.erase(it);
            } else {
                ++it;
            }
        }
    }
    G.gpu.ctx->ClearState();
    Paint();

    // After a burst of loading (shader compiles, image decoding), hand the memory that's no longer
    // touched back to Windows. Live previews keep what they draw with.
    bool busy;
    {
        std::lock_guard<std::mutex> g(W.lock);
        busy = !W.jobs.empty() || !W.done.empty();
    }
    static double quietSince = 0;
    static bool trimmed = true;
    if (busy || newRequests) {
        quietSince = now;
        trimmed = false;
    } else if (!trimmed && now - quietSince > 1.5) {
        trimmed = true;
        SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
        HeapCompact(GetProcessHeap(), 0);
    }
}

// ---------------------------------------------------------------------------------------------
// Window

std::vector<ComPtr<IDWriteTextFormat>*> Fonts() {
    std::vector<ComPtr<IDWriteTextFormat>*> all;
    for (auto& f : {std::ref(G.kind), std::ref(G.title), std::ref(G.body), std::ref(G.statValue), std::ref(G.statLabel),
                    std::ref(G.button), std::ref(G.tabFont), std::ref(G.tabOn), std::ref(G.name), std::ref(G.pill), std::ref(G.icon)})
        all.push_back(std::addressof(f.get()));
    return all;
}

bool CreateTarget() {
    G.dc->SetTarget(nullptr);
    G.target.Reset();
    ComPtr<IDXGISurface> back;
    if (FAILED(G.swap->GetBuffer(0, IID_PPV_ARGS(&back)))) return false;
    D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), G.dpi, G.dpi);
    if (FAILED(G.dc->CreateBitmapFromDxgiSurface(back.Get(), &bp, &G.target))) return false;
    G.dc->SetTarget(G.target.Get());
    G.dc->SetDpi(G.dpi, G.dpi);
    return true;
}

void Resize() {
    RECT rc;
    GetClientRect(G.wnd, &rc);
    if (!G.swap || rc.right <= 0 || rc.bottom <= 0) return;
    G.dc->SetTarget(nullptr);
    G.target.Reset();
    G.swap->ResizeBuffers(0, rc.right, rc.bottom, DXGI_FORMAT_UNKNOWN, 0);
    CreateTarget();
    Layout();
}

int HitTile(float x, float y) {
    if (y < TabsY() + kTabsH + 8) return -1;
    for (size_t k = 0; k < G.shown.size(); ++k) {
        D2D1_RECT_F r = TileRect(k);
        if (x >= r.left && x < r.right && y >= r.top && y < r.bottom + kNameH - 4) return (int)k;
    }
    return -1;
}

Hit HitTest(float x, float y, int& tile) {
    tile = -1;
    for (int i = 0; i < 3; ++i)
        if (In(G.tabs[i], x, y)) return (Hit)((int)Hit::Tab0 + i);
    if (In(G.open, x, y)) return Hit::Open;
    if (In(G.searchBox, x, y)) return Hit::Search;
    bool underStuckTabs = TabsY() <= 0.5f && y < kTabsH + 8;
    if (!underStuckTabs && HeroRect().bottom > 0) {
        if (In(G.apply, x, y)) return Hit::Apply;
        if (In(G.customize, x, y)) return Hit::Customize;
    }
    tile = HitTile(x, y);
    return tile >= 0 ? Hit::Tile : Hit::None;
}

void MoveSelection(int dx, int dy) {
    auto it = std::find(G.shown.begin(), G.shown.end(), G.selected);
    if (G.shown.empty()) return;
    int k = it == G.shown.end() ? 0 : (int)(it - G.shown.begin()) + dx + dy * G.cols;
    k = std::clamp(k, 0, (int)G.shown.size() - 1);
    Select(G.shown[k]);
    ScrollIntoView(G.shown[k]);
}

void Teardown() {
    KillTimer(G.wnd, kTimerFrame);
    StopWorkers();
    ReleasePreview(G.hero);
    G.tiles.clear();
    G.shown.clear();
    if (G.dc) G.dc->SetTarget(nullptr);
    G.blur.Reset();
    G.shade.Reset();
    G.redFill.Reset();
    G.target.Reset();
    G.brush.Reset();
    for (auto* f : Fonts()) f->Reset();
    G.dc.Reset();
    G.d2dDevice.Reset();
    G.d2d.Reset();
    G.dw.Reset();
    G.swap.Reset();
    G.gpu.Reset();
    G.wnd = nullptr;
}

LRESULT CALLBACK GalleryProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_TIMER:
        if (w == kTimerFrame) Frame();
        return 0;
    case WM_APP_PREVIEW:
        TakeFinished();
        return 0;
    case WM_SIZE:
        Resize();
        return 0;
    case WM_DPICHANGED: {
        G.dpi = HIWORD(w);
        auto* r = (RECT*)l;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        Resize();
        return 0;
    }
    case WM_GETMINMAXINFO: {
        auto* mm = (MINMAXINFO*)l;
        mm->ptMinTrackSize = {(LONG)Px(900), (LONG)Px(600)};
        return 0;
    }
    case WM_MOUSEWHEEL:
        G.scrollTarget -= GET_WHEEL_DELTA_WPARAM(w) / (float)WHEEL_DELTA * 160;
        G.scrollTarget = std::clamp(G.scrollTarget, 0.0f, MaxScroll());
        return 0;
    case WM_MOUSEMOVE: {
        float x = GET_X_LPARAM(l) * 96.0f / G.dpi, y = GET_Y_LPARAM(l) * 96.0f / G.dpi;
        G.hover = HitTest(x, y, G.hoverTile);
        if (!G.tracking) {
            TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE, h, 0};
            G.tracking = TrackMouseEvent(&tme);
        }
        return 0;
    }
    case WM_MOUSELEAVE:
        G.hover = Hit::None;
        G.hoverTile = -1;
        G.tracking = false;
        return 0;
    case WM_SETCURSOR:
        if (LOWORD(l) == HTCLIENT) {
            bool hand = G.hover != Hit::None && G.hover != Hit::Search;
            SetCursor(LoadCursorW(nullptr, G.hover == Hit::Search ? IDC_IBEAM : hand ? IDC_HAND : IDC_ARROW));
            return TRUE;
        }
        break;
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK: {
        float x = GET_X_LPARAM(l) * 96.0f / G.dpi, y = GET_Y_LPARAM(l) * 96.0f / G.dpi;
        int tile;
        switch (HitTest(x, y, tile)) {
        case Hit::Tab0: case Hit::Tab1: case Hit::Tab2:
            G.tab = (int)HitTest(x, y, tile) - (int)Hit::Tab0;
            Refilter();
            break;
        case Hit::Open: OpenFile(); break;
        case Hit::Apply: SetAsWallpaper(); break;
        case Hit::Customize:
            SetAsWallpaper();  // the settings window adjusts the wallpaper in use
            RunSelf(L"--settings");
            break;
        case Hit::Tile:
            Select(G.shown[tile]);
            if (msg == WM_LBUTTONDBLCLK) SetAsWallpaper();
            break;
        default: break;
        }
        return 0;
    }
    case WM_KEYDOWN:
        switch (w) {
        case VK_ESCAPE:
            if (!G.search.empty()) {
                G.search.clear();
                Refilter();
            } else {
                DestroyWindow(h);
            }
            break;
        case VK_LEFT: MoveSelection(-1, 0); break;
        case VK_RIGHT: MoveSelection(1, 0); break;
        case VK_UP: MoveSelection(0, -1); break;
        case VK_DOWN: MoveSelection(0, 1); break;
        case VK_RETURN: SetAsWallpaper(); break;
        case VK_HOME: G.scrollTarget = 0; break;
        case VK_END: G.scrollTarget = MaxScroll(); break;
        }
        return 0;
    case WM_CHAR:
        if (w == VK_BACK) {
            if (!G.search.empty()) G.search.pop_back();
        } else if (w >= 32 && w != 127) {
            G.search += (wchar_t)w;
        } else {
            return 0;
        }
        G.scrollTarget = std::min(G.scrollTarget, G.tabsTop);  // keep the results in view
        Refilter();
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        ValidateRect(h, nullptr);
        if (G.target) Paint();
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);  // the gallery process ends with its window
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

bool InitGraphics() {
    if (!G.gpu.Init()) return false;
    ComPtr<IDXGIDevice> dxgi;
    D2D1_FACTORY_OPTIONS opts{};
    if (FAILED(G.gpu.dev.As(&dxgi)) ||
        FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &opts, (void**)&G.d2d)) ||
        FAILED(G.d2d->CreateDevice(dxgi.Get(), &G.d2dDevice)) ||
        FAILED(G.d2dDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &G.dc)) ||
        FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown**)G.dw.GetAddressOf())) ||
        FAILED(G.dc->CreateSolidColorBrush(Color::Text, &G.brush)))
        return false;
    G.dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);

    if (SUCCEEDED(G.dc->CreateEffect(CLSID_D2D1GaussianBlur, &G.blur))) {
        G.blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION, 16.0f);
        G.blur->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE, D2D1_BORDER_MODE_HARD);
        G.blur->SetValue(D2D1_GAUSSIANBLUR_PROP_OPTIMIZATION, D2D1_GAUSSIANBLUR_OPTIMIZATION_SPEED);
    }
    D2D1_GRADIENT_STOP shade[] = {{0, Rgb(0x0A0A0C, 0.50f)}, {0.6f, Rgb(0x0A0A0C, 0.90f)}, {1, Rgb(0x0A0A0C, 0.96f)}};
    D2D1_GRADIENT_STOP red[] = {{0, Rgb(0xFF4141)}, {1, Rgb(0xD61F1F)}};
    ComPtr<ID2D1GradientStopCollection> s1, s2;
    if (FAILED(G.dc->CreateGradientStopCollection(shade, 3, &s1)) || FAILED(G.dc->CreateGradientStopCollection(red, 2, &s2)) ||
        FAILED(G.dc->CreateLinearGradientBrush({}, s1.Get(), &G.shade)) || FAILED(G.dc->CreateLinearGradientBrush({}, s2.Get(), &G.redFill)))
        return false;

    const wchar_t* text = HasFamily(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    const wchar_t* display = HasFamily(L"Segoe UI Variable Display") ? L"Segoe UI Variable Display" : L"Segoe UI";
    const wchar_t* icons = HasFamily(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    G.kind = Font(text, 12, DWRITE_FONT_WEIGHT_BOLD);
    G.title = Font(display, 44, DWRITE_FONT_WEIGHT_BOLD);
    G.body = Font(text, 15, DWRITE_FONT_WEIGHT_NORMAL, true);
    G.statValue = Font(text, 17, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    G.statLabel = Font(text, 12, DWRITE_FONT_WEIGHT_NORMAL);
    G.button = Font(text, 14, DWRITE_FONT_WEIGHT_SEMI_BOLD, false, DWRITE_TEXT_ALIGNMENT_CENTER);
    G.tabFont = Font(text, 14, DWRITE_FONT_WEIGHT_NORMAL);
    G.tabOn = Font(text, 14, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    G.name = Font(text, 12.5f, DWRITE_FONT_WEIGHT_NORMAL);
    G.pill = Font(text, 12, DWRITE_FONT_WEIGHT_SEMI_BOLD);
    G.icon = Font(icons, 13, DWRITE_FONT_WEIGHT_NORMAL);
    for (auto* f : Fonts())
        if (!*f) return false;
    return true;
}

}  // namespace

// Opens the gallery in its own process, or brings an open one forward.
void ShowGallery() {
    if (HWND open = FindWindowW(kClass, nullptr)) {
        if (IsIconic(open)) ShowWindow(open, SW_RESTORE);
        SetForegroundWindow(open);
        return;
    }
    RunSelf(L"--gallery-window");
}

// LiteWallpaper.exe --gallery-window: the gallery process itself.
int RunGalleryWindow() {
    if (HWND open = FindWindowW(kClass, nullptr)) {
        SetForegroundWindow(open);
        return 0;
    }
    WNDCLASSEXW wc{sizeof(wc)};
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = GalleryProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = AppIcon(true);
    wc.hIconSm = AppIcon();
    wc.lpszClassName = kClass;
    RegisterClassExW(&wc);
    if (!InitGraphics()) {
        Teardown();
        MessageBoxW(nullptr, L"The wallpaper gallery needs Direct3D 11 and Direct2D.", L"LiteWallpaper", MB_OK | MB_ICONWARNING);
        return 1;
    }

    // Centered on the monitor under the mouse, 1280 x 820 DIPs at most.
    POINT pt;
    GetCursorPos(&pt);
    MONITORINFO mi{sizeof(mi)};
    GetMonitorInfoW(MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY), &mi);
    HWND wnd = CreateWindowExW(0, kClass, L"LiteWallpaper", WS_OVERLAPPEDWINDOW, mi.rcWork.left, mi.rcWork.top, 100, 100,
                               nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!wnd) {
        Teardown();
        return 1;
    }
    G.wnd = wnd;
    G.dpi = (float)GetDpiForWindow(wnd);
    BOOL dark = TRUE;
    DwmSetWindowAttribute(wnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    COLORREF caption = RGB(0x0E, 0x0E, 0x10);
    DwmSetWindowAttribute(wnd, 35 /* DWMWA_CAPTION_COLOR, Windows 11 */, &caption, sizeof(caption));
    int ww = std::min((int)Px(1280), (int)(mi.rcWork.right - mi.rcWork.left) * 9 / 10);
    int wh = std::min((int)Px(820), (int)(mi.rcWork.bottom - mi.rcWork.top) * 9 / 10);
    SetWindowPos(wnd, nullptr, mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - ww) / 2,
                 mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - wh) / 2, ww, wh, SWP_NOZORDER | SWP_NOACTIVATE);

    RECT rc;
    GetClientRect(wnd, &rc);
    DXGI_SWAP_CHAIN_DESC1 d{};
    d.Width = std::max(1L, rc.right);
    d.Height = std::max(1L, rc.bottom);
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    d.BufferCount = 2;
    d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    if (FAILED(G.gpu.factory->CreateSwapChainForHwnd(G.gpu.dev.Get(), wnd, &d, nullptr, nullptr, &G.swap)) || !CreateTarget()) {
        DestroyWindow(wnd);
        MessageBoxW(nullptr, L"Couldn't open the wallpaper gallery.", L"LiteWallpaper", MB_OK | MB_ICONWARNING);
        return 1;
    }
    G.gpu.factory->MakeWindowAssociation(wnd, DXGI_MWA_NO_ALT_ENTER);

    G.cfg = LoadConfig();
    G.cfg.fps = 30;
    G.current = ToLower(ResolvePath(G.cfg.def.source));
    for (auto& e : ListWallpapers()) {
        Tile t;
        t.entry = e;
        t.path = ResolvePath(e.rel);
        t.key = ToLower(t.path);
        t.name = Pretty(e.label.substr(e.label.find(L':') + 2));
        t.particles = e.label.rfind(L"Particles", 0) == 0;
        if (!t.particles) t.desc = FileDescription(t.path);
        G.tiles.push_back(std::move(t));
    }
    if (G.tiles.empty()) {
        DestroyWindow(wnd);
        MessageBoxW(nullptr, L"No wallpapers were found next to LiteWallpaper.exe.", L"LiteWallpaper", MB_OK | MB_ICONWARNING);
        return 1;
    }
    Refilter();
    // Start on the wallpaper in use.
    for (size_t i = 0; i < G.tiles.size(); ++i)
        if (G.tiles[i].key == G.current) G.selected = i;
    Select(G.selected);
    G.heroPath = G.tiles[G.selected].path;

    G.start = Now();
    // A few loaders at once (shader compiles are CPU-bound), leaving cores free for everything else.
    unsigned loaders = std::clamp(std::thread::hardware_concurrency() / 6, 1u, 2u);
    for (unsigned i = 0; i < loaders; ++i) W.threads.emplace_back(WorkerMain);
    SetTimer(wnd, kTimerFrame, 15, nullptr);
    ShowWindow(wnd, SW_SHOW);
    SetForegroundWindow(wnd);
    Frame();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    // Closed. A loader may be in the middle of compiling a shader; there's nothing to save, so end
    // the process now rather than wait for it, and let Windows reclaim everything.
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}
