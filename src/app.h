#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_3.h>
#include <wrl/client.h>
#include <memory>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

extern HWND g_mainWnd;
extern bool g_diag;  // --diag: log extra detail
constexpr UINT WM_APP_VIDEO = WM_APP + 2;  // wParam = media engine event, lParam = Source*

// ---- util / config (config.cpp) ----
std::wstring ExeDir();   // the program and its bundled shaders/particles
std::wstring DataDir();  // this Windows user's settings, profiles and log (%APPDATA%\LiteWallpaper)
std::wstring ResolvePath(const std::wstring& path);
std::wstring ToLower(std::wstring s);
std::wstring FileName(const std::wstring& path);
std::wstring Utf8ToWide(const std::string& s);
std::string WideToUtf8(const std::wstring& s);
void Log(const wchar_t* fmt, ...);

enum class Fit { Cover, Contain, Stretch };

struct ScreenConfig {
    std::wstring source;
    Fit fit = Fit::Cover;
    float scale = 1.0f;
};

struct Config {
    int fps = 30;
    int videoFps = 60;
    bool pauseOnFullscreen = true;
    bool pauseWhenCovered = true;
    bool pauseOnBattery = true;
    std::vector<std::wstring> pauseApps;  // lower-case exe names
    ScreenConfig def;
    std::vector<std::pair<int, ScreenConfig>> perMonitor;  // 1-based monitor index

    ScreenConfig ForMonitor(int index) const;
};

std::wstring ConfigPath();  // settings file of the active profile
Config LoadConfig();

// Profiles: "" is Default (wallpaper.ini); others live in profiles\<name>.ini.
void LoadActiveProfile();  // resolves the remembered profile; call first thing at startup
std::wstring ActiveProfile();
void SetActiveProfile(const std::wstring& name);
std::vector<std::wstring> ListProfiles();
bool SaveProfileAs(const std::wstring& name, std::wstring& error);  // copies the current settings, then switches
void DeleteProfile(const std::wstring& name);
bool UserWantsAutostart();  // false once this user turned "Start with Windows" off
void SetUserAutostart(bool on);
// ini section holding the settings window's tweaks for one wallpaper file ("override:...").
std::wstring OverrideSection(const std::wstring& fullPath);
float IniFloat(const std::wstring& section, const wchar_t* key, float def);

// ---- main.cpp: used by the settings window ----
struct WallpaperEntry {
    std::wstring rel;    // path as written in wallpaper.ini
    std::wstring label;  // "Shader: aurora"
};
std::vector<WallpaperEntry> ListWallpapers();
std::wstring CurrentSource();  // resolved [default] source
void RequestReload();          // re-read settings shortly (debounced)
bool StartupEnabled();  // for the signed-in user
void SetStartup(bool enable);
bool AllUsersStartupEnabled();  // machine-wide sign-in task for every user
bool SetAllUsersStartup(bool enable, HWND owner);  // asks for admin rights; false if it didn't happen
HICON AppIcon(bool large = false);

void ShowNotice(const std::wstring& title, const std::wstring& text);  // tray notification
bool AutoUpdateEnabled();  // [app] auto_update in the user's wallpaper.ini (on unless turned off)
void SetAutoUpdate(bool on);

// ---- updater.cpp: updates from GitHub releases ----
constexpr UINT WM_APP_UPDATE = WM_APP + 3;  // a background update check finished
std::wstring AppVersion();  // "1.2.3", or "dev" for local builds
bool UpdatesSupported();    // false for local builds
void StartUpdateCheck(bool userAsked);  // automatic checks also download; the menu asks first
void OnUpdateCheckDone(HWND owner);
bool UpdateBusy();
bool UpdateWaiting();  // downloaded and installable without admin rights
bool InstallStagedUpdate(HWND owner, bool interactive);  // replaces the files and restarts the app
std::wstring UpdateMenuText();
void UpdateMenuCommand(HWND owner);
int InstallUpdateCommand(const std::wstring& staged, const std::wstring& dir, const std::wstring& exeName,
                         const std::wstring& version);  // elevated
void FinishUpdate(DWORD oldPid);  // first start after an update: waits for the old process
void ShowUpdatedNotice();
void CleanUpOldUpdate();

// ---- settings_ui.cpp ----
void ShowSettings();
HWND SettingsWindow();  // nullptr when closed
void RefreshUpdateButton();

// ---- desktop.cpp ----
struct DesktopHost {
    HWND parent = nullptr;       // window our wallpaper windows become children of
    HWND insertAfter = nullptr;  // sibling to sit directly below (the icon layer on 24H2+)
};
DesktopHost FindDesktopHost();
void DumpDesktopTree();
void RefreshDesktop(const DesktopHost& host);

// ---- gpu.cpp ----
struct FrameConstants {
    float resX, resY, time, frame;
    float uvScaleX, uvScaleY, uvOffsetX, uvOffsetY;
    float extra[4];
};

class Source;

struct Screen {
    int index = 0;  // 1-based, left to right
    RECT rc{};      // monitor rect, screen coordinates
    RECT work{};    // monitor work area
    ScreenConfig cfg;
    Source* src = nullptr;
    HWND hwnd = nullptr;
    ComPtr<IDXGISwapChain1> swap;
    ComPtr<ID3D11Texture2D> backBuffer;
    ComPtr<ID3D11RenderTargetView> rtv;
    UINT bw = 0, bh = 0;  // back buffer size (smaller than the window when scale < 1)
    float scale = 1;      // back buffer scale the swap chain was created with
    bool covered = false;
    bool needsDraw = true;
};

struct Gpu {
    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;
    ComPtr<IDXGIFactory2> factory;
    ComPtr<ID3D11VertexShader> vs;
    ComPtr<ID3D11PixelShader> psTex;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11Buffer> cb;

    bool Init();
    void Reset();
    void Trim();
    void SetConstants(const FrameConstants& c);
    void DrawFullscreen(Screen& s, ID3D11PixelShader* ps, ID3D11ShaderResourceView* srv);
};

bool CreateScreenSurface(Gpu& gpu, Screen& s, const DesktopHost& host, float scale);
void DestroyScreenSurface(Screen& s);
// Maps screen UV to source UV: out = {scaleX, scaleY, offsetX, offsetY}.
void FitTransform(Fit fit, float srcW, float srcH, float dstW, float dstH, float out[4]);

// ---- sources.cpp ----

// A decoded image on the GPU. Animated GIFs are decoded one frame at a time onto a single
// canvas, so memory stays at one frame however long the GIF is.
class Picture {
public:
    Picture();
    ~Picture();
    bool Load(Gpu& gpu, const std::wstring& path, std::wstring& error);
    bool Animated() const;
    double NextDue() const;      // HUGE_VAL for still images
    bool Advance(double now);    // true when the visible frame changed
    void Restart(double now);    // call when resuming after a pause
    ID3D11ShaderResourceView* Srv(Gpu& gpu);  // uploads a pending frame first
    UINT Width() const;
    UINT Height() const;

private:
    struct Impl;
    std::unique_ptr<Impl> p_;
};

class Source {
public:
    virtual ~Source() = default;
    // Clock time of the next update; HUGE_VAL when the source never changes on its own.
    virtual double NextDue() const = 0;
    // Advances the source. Returns true when its screens need redrawing.
    virtual bool Update(double now, double animTime) = 0;
    virtual void Draw(Gpu& gpu, Screen& s) = 0;
    virtual void SetActive(bool active, double now) {}
    // Render resolution for this source, given the configured one. Only shaders render below 1.
    virtual float RenderScale(float configured) const { return 1.0f; }
    // Handles a media engine event. Returns true when screens need redrawing.
    virtual bool OnVideoEvent(DWORD event, std::wstring& error) { return false; }

    std::wstring key;
    bool active = false;
};

std::unique_ptr<Source> CreateSource(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& error);
std::unique_ptr<Source> CreateBuiltinSource(Gpu& gpu, const Config& cfg, std::wstring& error);

// ---- particles.cpp ----
// particles.js (github.com/VincentGarreau/particles.js) config files, simulated natively.
std::unique_ptr<Source> CreateParticleSource(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& error);
struct Json;
// Reads a particles.js config and applies the settings window's overrides on top.
bool LoadParticleJson(const std::wstring& path, Json& root, std::wstring& error);
