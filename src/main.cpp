#include "app.h"
#include <commctrl.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <taskschd.h>
#include <wtsapi32.h>
#include <algorithm>
#include <cmath>
#include <map>

HWND g_mainWnd = nullptr;
bool g_diag = false;

namespace {

constexpr UINT WM_TRAY = WM_APP + 1;
constexpr UINT_PTR kTimerPoll = 1, kTimerRebuild = 2, kTimerReload = 3, kTimerUpdate = 4;
constexpr UINT kFirstUpdateCheck = 90 * 1000, kUpdateCheckEvery = 6 * 3600 * 1000, kUpdateRetry = 10 * 60 * 1000;
enum : UINT { ID_STATUS = 100, ID_PAUSE, ID_SETTINGS, ID_EDITFILE, ID_RELOAD, ID_FOLDER, ID_DATAFOLDER, ID_STARTUP,
               ID_STARTUPALL, ID_VERSION, ID_UPDATE, ID_EXIT, ID_WALLPAPER = 1000, ID_PROFILE = 2000 };

const wchar_t kAppName[] = L"LiteWallpaper";
const wchar_t kMainClass[] = L"LiteWallpaper.Main";
const wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const GUID kGuidDisplayState = {0x6FE69556, 0x704A, 0x47A0, {0x8F, 0x24, 0xC2, 0x8D, 0x93, 0x6F, 0xDA, 0x47}};
const GUID kGuidAcDcSource = {0x5D3E9A59, 0xE9D5, 0x4B00, {0xA6, 0xBD, 0xFF, 0x34, 0xFF, 0x51, 0x65, 0x48}};

struct State {
    Config cfg;
    Gpu gpu;
    DesktopHost host;
    std::vector<std::unique_ptr<Screen>> screens;
    std::vector<std::unique_ptr<Source>> sources;
    std::map<std::wstring, FILETIME> watched;  // files whose edits trigger a reload
    std::vector<std::wstring> menuFiles;       // tray "Wallpaper" entries, ID_WALLPAPER + index
    std::vector<std::wstring> menuProfiles;    // tray "Profile" entries, ID_PROFILE + index

    bool userPaused = false, locked = false, displayOff = false;
    bool paused = true;
    std::wstring status = L"Starting";
    double animTime = 0, lastTick = 0, trimAt = 0;

    UINT taskbarCreated = 0;
    NOTIFYICONDATAW nid{};
    HANDLE timer = nullptr;
    HANDLE dirWatch[2] = {INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE};  // app folder, user settings folder
    bool diag = false;
} S;

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

void TrimWorkingSet() { SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1); }

// ---------------------------------------------------------------------------------------------
// Tray
// ---------------------------------------------------------------------------------------------

// The ribbon icon embedded by app.rc, at the size the current DPI calls for.
HICON LoadAppIcon(bool large) {
    HICON icon = nullptr;
    if (FAILED(LoadIconMetric(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), large ? LIM_LARGE : LIM_SMALL, &icon)))
        icon = LoadIconW(nullptr, IDI_APPLICATION);
    return icon;
}

void SetTrayTip() {
    swprintf_s(S.nid.szTip, L"%s - %s", kAppName, S.status.c_str());
    S.nid.uFlags = NIF_TIP;
    Shell_NotifyIconW(NIM_MODIFY, &S.nid);
}

void AddTray() {
    S.nid.cbSize = sizeof(S.nid);
    S.nid.hWnd = g_mainWnd;
    S.nid.uID = 1;
    S.nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    S.nid.uCallbackMessage = WM_TRAY;
    if (!S.nid.hIcon) S.nid.hIcon = LoadAppIcon(false);
    swprintf_s(S.nid.szTip, L"%s - %s", kAppName, S.status.c_str());
    Shell_NotifyIconW(NIM_ADD, &S.nid);
}

void ShowBalloon(const std::wstring& title, const std::wstring& text, DWORD icon = NIIF_WARNING) {
    NOTIFYICONDATAW n = S.nid;
    n.uFlags = NIF_INFO;
    wcsncpy_s(n.szInfoTitle, title.c_str(), _TRUNCATE);
    wcsncpy_s(n.szInfo, text.c_str(), _TRUNCATE);
    n.dwInfoFlags = icon;
    Shell_NotifyIconW(NIM_MODIFY, &n);
}

// ---------------------------------------------------------------------------------------------
// Pause detection
// ---------------------------------------------------------------------------------------------

bool IsShellWindow(HWND h) {
    if (h == GetShellWindow() || h == GetDesktopWindow()) return true;
    wchar_t cls[64] = L"";
    GetClassNameW(h, cls, ARRAYSIZE(cls));
    static const wchar_t* shell[] = {L"Progman", L"WorkerW", L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd",
                                     L"NotifyIconOverflowWindow", L"Windows.UI.Core.CoreWindow",
                                     L"XamlExplorerHostIslandWindow", L"TopLevelWindowForOverflowXamlIsland"};
    for (auto s : shell)
        if (!wcscmp(cls, s)) return true;
    return false;
}

bool IsOwnWindow(HWND h) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    return pid == GetCurrentProcessId();
}

bool Covers(const RECT& a, const RECT& b) {
    return a.left <= b.left && a.top <= b.top && a.right >= b.right && a.bottom >= b.bottom;
}

std::wstring WindowExeName(HWND h) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    std::wstring name;
    if (HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
        wchar_t path[MAX_PATH * 2];
        DWORD size = ARRAYSIZE(path);
        if (QueryFullProcessImageNameW(p, 0, path, &size)) name = FileName(path);
        CloseHandle(p);
    }
    return name.empty() ? L"an app" : name;
}

// A window someone can actually see: not hidden, cloaked (another virtual desktop, a suspended
// UWP app), click-through or fully transparent. Laptops especially have invisible full-screen
// helper windows (GPU overlays, OEM utilities) that can end up with the focus.
bool ActuallyVisible(HWND h) {
    if (!IsWindowVisible(h) || IsIconic(h)) return false;
    BOOL cloaked = FALSE;
    DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    if (cloaked) return false;
    LONG ex = GetWindowLongW(h, GWL_EXSTYLE);
    if (ex & (WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)) return false;
    BYTE alpha = 255;
    DWORD flags = 0;
    if ((ex & WS_EX_LAYERED) && GetLayeredWindowAttributes(h, nullptr, &alpha, &flags) && (flags & LWA_ALPHA) && alpha == 0)
        return false;
    return true;
}

// The exe of a game or app running fullscreen (exclusive or borderless, presentations, F11
// browsers), or "" when there's none. Windows' own "busy" state isn't used: it's also set by
// presentation/Focus settings and by invisible full-screen windows, and paused the wallpaper for good.
std::wstring FullscreenApp() {
    HWND fg = GetForegroundWindow();
    QUERY_USER_NOTIFICATION_STATE q = QUNS_ACCEPTS_NOTIFICATIONS;
    if (SUCCEEDED(SHQueryUserNotificationState(&q)) && q == QUNS_RUNNING_D3D_FULL_SCREEN)
        return fg ? WindowExeName(fg) : L"a game";  // exclusive fullscreen Direct3D
    if (q == QUNS_PRESENTATION_MODE) return L"presentation mode";

    if (!fg || IsShellWindow(fg) || IsOwnWindow(fg) || !ActuallyVisible(fg)) return L"";
    // A maximized window isn't "fullscreen", even with an auto-hide taskbar; if it hides the
    // desktop, "pause when covered" handles it.
    if (IsZoomed(fg)) return L"";
    HMONITOR mon = MonitorFromWindow(fg, MONITOR_DEFAULTTONULL);
    MONITORINFO mi{sizeof(mi)};
    if (!mon || !GetMonitorInfoW(mon, &mi)) return L"";
    RECT r;
    if (FAILED(DwmGetWindowAttribute(fg, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof(r))) && !GetWindowRect(fg, &r)) return L"";
    if (!Covers(r, mi.rcMonitor)) return L"";
    wchar_t cls[128] = L"";
    GetClassNameW(fg, cls, ARRAYSIZE(cls));
    std::wstring app = WindowExeName(fg);
    static HWND logged = nullptr;  // once per window, so the log says what it was
    if (fg != logged) {
        logged = fg;
        Log(L"Fullscreen: %s (window class %s, %ld,%ld %ldx%ld)", app.c_str(), cls, r.left, r.top, r.right - r.left, r.bottom - r.top);
    }
    return app;
}

// lp = one region per screen holding the part of its work area no window has covered yet.
BOOL CALLBACK CoverProc(HWND h, LPARAM lp) {
    auto& visible = *(std::vector<HRGN>*)lp;
    if (!IsWindowVisible(h) || IsIconic(h) || IsShellWindow(h) || IsOwnWindow(h)) return TRUE;
    LONG ex = GetWindowLongW(h, GWL_EXSTYLE);
    // Click-through overlays (GPU overlays, screen recorders) cover the screen but hide nothing.
    if (ex & (WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)) return TRUE;
    if ((ex & WS_EX_LAYERED) && !IsZoomed(h)) return TRUE;
    BOOL cloaked = FALSE;  // windows on other virtual desktops, suspended UWP apps
    DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    if (cloaked) return TRUE;
    RECT r;
    if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof(r)))) GetWindowRect(h, &r);
    HRGN win = CreateRectRgnIndirect(&r);
    bool anyLeft = false;
    for (HRGN v : visible)
        if (CombineRgn(v, v, win, RGN_DIFF) != NULLREGION) anyLeft = true;
    DeleteObject(win);
    return anyLeft;  // stop early once every screen is hidden
}

LONGLONG RegionArea(HRGN rgn) {
    DWORD size = GetRegionData(rgn, 0, nullptr);
    std::vector<BYTE> buf(size);
    if (!size || !GetRegionData(rgn, size, (RGNDATA*)buf.data())) return 0;
    auto* data = (RGNDATA*)buf.data();
    auto* rects = (RECT*)data->Buffer;
    LONGLONG area = 0;
    for (DWORD i = 0; i < data->rdh.nCount; ++i)
        area += (LONGLONG)(rects[i].right - rects[i].left) * (rects[i].bottom - rects[i].top);
    return area;
}

// A screen counts as covered when windows hide all but a sliver of it, whether that's one
// maximized window or several snapped side by side.
void UpdateCovered() {
    std::vector<HRGN> visible;
    for (auto& s : S.screens) visible.push_back(CreateRectRgnIndirect(&s->work));
    EnumWindows(CoverProc, (LPARAM)&visible);
    for (size_t i = 0; i < S.screens.size(); ++i) {
        const RECT& w = S.screens[i]->work;
        LONGLONG total = (LONGLONG)(w.right - w.left) * (w.bottom - w.top);
        S.screens[i]->covered = RegionArea(visible[i]) * 200 <= total;  // under 0.5% still showing
        DeleteObject(visible[i]);
    }
}

std::wstring RunningPauseApp() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return L"";
    PROCESSENTRY32W pe{sizeof(pe)};
    std::wstring found;
    for (BOOL ok = Process32FirstW(snap, &pe); ok && found.empty(); ok = Process32NextW(snap, &pe)) {
        std::wstring name = ToLower(pe.szExeFile);
        for (auto& app : S.cfg.pauseApps)
            if (name == app) found = pe.szExeFile;
    }
    CloseHandle(snap);
    return found;
}

// A game or other fullscreen app, or a program the user listed, is running: whatever the pause
// settings say, this is no time for an update to restart the app.
bool Gaming() { return !FullscreenApp().empty() ||(!S.cfg.pauseApps.empty() && !RunningPauseApp().empty()); }

void ApplyActivity() {
    double now = Now();
    for (auto& src : S.sources) {
        bool want = false;
        if (!S.paused)
            for (auto& s : S.screens)
                if (s->src == src.get() && !s->covered) want = true;
        if (want == src->active) continue;
        src->active = want;
        src->SetActive(want, now);
        if (want)
            for (auto& s : S.screens)
                if (s->src == src.get()) s->needsDraw = true;
    }
}

void UpdatePause() {
    if (S.screens.empty()) return;

    std::wstring reason;
    SYSTEM_POWER_STATUS ps;
    if (S.userPaused) reason = L"Paused";
    else if (S.locked) reason = L"Paused (locked)";
    else if (S.displayOff) reason = L"Paused (display off)";
    else if (S.cfg.pauseOnBattery && GetSystemPowerStatus(&ps) && ps.ACLineStatus == 0) reason = L"Paused (on battery)";
    else if (std::wstring app = S.cfg.pauseOnFullscreen ? FullscreenApp() : L""; !app.empty())
        reason = L"Paused (" + app + L" is fullscreen)";
    else if (!S.cfg.pauseApps.empty()) {
        std::wstring app = RunningPauseApp();
        if (!app.empty()) reason = L"Paused (" + app + L" is running)";
    }

    if (reason.empty()) {
        if (S.cfg.pauseWhenCovered) UpdateCovered();
        else for (auto& s : S.screens) s->covered = false;
        bool anyVisible = std::any_of(S.screens.begin(), S.screens.end(), [](auto& s) { return !s->covered; });
        if (!anyVisible) reason = L"Paused (desktop covered)";
    }

    bool paused = !reason.empty();
    std::wstring status = paused ? reason : L"Playing";
    bool wasPaused = S.paused;
    S.paused = paused;
    if (wasPaused && !paused) S.lastTick = Now();
    ApplyActivity();

    if (status != S.status) {
        S.status = status;
        SetTrayTip();
        if (S.diag) Log(L"Status: %s", status.c_str());
    }
    // Going idle: hand back GPU scratch memory and page out everything we aren't using.
    if (paused && (!wasPaused || S.trimAt > 0)) {
        S.trimAt = 0;
        S.gpu.Trim();
        TrimWorkingSet();
    }
}

// ---------------------------------------------------------------------------------------------
// Build / teardown
// ---------------------------------------------------------------------------------------------

FILETIME LastWrite(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA fa{};
    GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fa);
    return fa.ftLastWriteTime;
}

void Watch(const std::wstring& path) { S.watched[path] = LastWrite(path); }

bool WatchedFilesChanged() {
    for (auto& [path, time] : S.watched) {
        FILETIME now = LastWrite(path);
        if (CompareFileTime(&time, &now) != 0) return true;
    }
    return false;
}

Source* GetSource(const std::wstring& configured) {
    std::wstring path = ResolvePath(configured);
    std::wstring key = ToLower(path);
    for (auto& s : S.sources)
        if (s->key == key) return s.get();

    std::wstring err;
    std::unique_ptr<Source> src;
    if (!path.empty()) {
        Watch(path);
        src = CreateSource(S.gpu, path, S.cfg, err);
        if (!src) {
            Log(L"Could not load %s: %s", path.c_str(), err.c_str());
            ShowBalloon(L"Couldn't load " + FileName(path), err);
        }
    }
    if (!src) {
        key = L"<builtin>";
        for (auto& s : S.sources)
            if (s->key == key) return s.get();
        src = CreateBuiltinSource(S.gpu, S.cfg, err);
        if (!src) {
            Log(L"Built-in shader failed: %s", err.c_str());
            return nullptr;
        }
    }
    src->key = key;
    S.sources.push_back(std::move(src));
    return S.sources.back().get();
}

void Teardown() {
    if (S.gpu.ctx) S.gpu.ctx->ClearState();
    for (auto& s : S.screens) DestroyScreenSurface(*s);
    S.screens.clear();
    S.sources.clear();
    if (S.gpu.ctx) S.gpu.ctx->Flush();
}

BOOL CALLBACK MonitorProc(HMONITOR m, HDC, LPRECT, LPARAM lp) {
    MONITORINFO mi{sizeof(mi)};
    if (GetMonitorInfoW(m, &mi)) ((std::vector<MONITORINFO>*)lp)->push_back(mi);
    return TRUE;
}

void Build() {
    KillTimer(g_mainWnd, kTimerRebuild);
    Teardown();
    S.cfg = LoadConfig();
    S.watched.clear();
    Watch(ConfigPath());

    if (!S.gpu.dev && !S.gpu.Init()) {
        S.gpu.Reset();
        S.status = L"No usable GPU";
        SetTrayTip();
        ShowBalloon(kAppName, L"Couldn't start Direct3D 11.");
        return;
    }

    S.host = FindDesktopHost();
    if (S.diag) DumpDesktopTree();
    if (!S.host.parent) {
        S.status = L"Waiting for the desktop";
        SetTrayTip();
        SetTimer(g_mainWnd, kTimerRebuild, 1000, nullptr);
        return;
    }

    std::vector<MONITORINFO> mons;
    EnumDisplayMonitors(nullptr, nullptr, MonitorProc, (LPARAM)&mons);
    std::sort(mons.begin(), mons.end(), [](const MONITORINFO& a, const MONITORINFO& b) {
        return a.rcMonitor.left != b.rcMonitor.left ? a.rcMonitor.left < b.rcMonitor.left : a.rcMonitor.top < b.rcMonitor.top;
    });

    for (size_t i = 0; i < mons.size(); ++i) {
        auto s = std::make_unique<Screen>();
        s->index = (int)i + 1;
        s->rc = mons[i].rcMonitor;
        s->work = mons[i].rcWork;
        s->cfg = S.cfg.ForMonitor(s->index);
        s->src = GetSource(s->cfg.source);
        if (!s->src) continue;
        float scale = s->src->RenderScale(s->cfg.scale);
        if (!CreateScreenSurface(S.gpu, *s, S.host, scale)) continue;
        s->scale = scale;
        if (S.diag)
            Log(L"Monitor %d: %dx%d at %d,%d -> %s (buffer %ux%u)", s->index, s->rc.right - s->rc.left,
                s->rc.bottom - s->rc.top, s->rc.left, s->rc.top, s->src->key.c_str(), s->bw, s->bh);
        S.screens.push_back(std::move(s));
    }

    S.paused = true;  // UpdatePause flips this and activates the sources
    S.lastTick = Now();
    S.trimAt = Now() + 3.0;  // drop start-up allocations once we're running
    UpdatePause();
}

// Settings changed: rebuild only the wallpaper sources and keep the windows and swap chains,
// so there's no flicker. Falls back to a full Build when a swap chain has to change size.
void ReloadSources() {
    KillTimer(g_mainWnd, kTimerReload);
    if (S.screens.empty() || !IsWindow(S.host.parent)) {
        Build();
        return;
    }
    if (S.gpu.ctx) S.gpu.ctx->ClearState();
    for (auto& s : S.screens) s->src = nullptr;
    S.sources.clear();
    S.cfg = LoadConfig();
    S.watched.clear();
    Watch(ConfigPath());
    for (auto& s : S.screens) {
        s->cfg = S.cfg.ForMonitor(s->index);
        s->src = GetSource(s->cfg.source);
        float scale = s->src ? s->src->RenderScale(s->cfg.scale) : 1.0f;
        if (!s->src || scale != s->scale) {
            Build();
            return;
        }
        s->needsDraw = true;
    }
    S.paused = true;  // UpdatePause flips this and activates the new sources
    S.lastTick = Now();
    UpdatePause();
}

void DeviceLost() {
    Log(L"GPU device lost, recreating");
    Teardown();
    S.gpu.Reset();
    SetTimer(g_mainWnd, kTimerRebuild, 500, nullptr);
}

// ---------------------------------------------------------------------------------------------
// Frame loop
// ---------------------------------------------------------------------------------------------

void Tick() {
    if (S.paused || S.screens.empty()) return;
    double now = Now();
    S.animTime += std::min(now - S.lastTick, 0.25);
    S.lastTick = now;

    for (auto& src : S.sources) {
        if (!src->active || now < src->NextDue()) continue;
        if (src->Update(now, S.animTime))
            for (auto& s : S.screens)
                if (s->src == src.get()) s->needsDraw = true;
    }
    for (auto& s : S.screens) {
        if (!s->needsDraw || s->covered) continue;
        s->needsDraw = false;
        s->src->Draw(S.gpu, *s);
        HRESULT hr = s->swap->Present(1, 0);
        if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
            DeviceLost();
            return;
        }
    }
    if (S.trimAt > 0 && now >= S.trimAt) {
        S.trimAt = 0;
        TrimWorkingSet();
    }
}

// Seconds until something needs doing; negative = nothing scheduled, sleep until a message.
double NextWait() {
    if (S.paused || S.screens.empty()) return -1;
    for (auto& s : S.screens)
        if (s->needsDraw && !s->covered) return 0;
    double due = HUGE_VAL;
    for (auto& src : S.sources)
        if (src->active) due = std::min(due, src->NextDue());
    if (S.trimAt > 0) due = std::min(due, S.trimAt);
    if (due == HUGE_VAL) return -1;
    return std::max(0.0, due - Now());
}

int Run() {
    MSG msg;
    for (;;) {
        double wait = NextWait();
        HANDLE handles[3];
        DWORD count = 0;
        for (HANDLE w : S.dirWatch)
            if (w != INVALID_HANDLE_VALUE) handles[count++] = w;
        const DWORD watches = count;
        if (wait > 0) {
            LARGE_INTEGER due;
            due.QuadPart = -(LONGLONG)(wait * 1e7);
            SetWaitableTimer(S.timer, &due, 0, nullptr, nullptr, FALSE);
            handles[count++] = S.timer;
        }
        DWORD r = wait == 0 ? WAIT_TIMEOUT
                            : MsgWaitForMultipleObjectsEx(count, handles, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (r - WAIT_OBJECT_0 < watches) {
            FindNextChangeNotification(handles[r - WAIT_OBJECT_0]);
            if (WatchedFilesChanged()) SetTimer(g_mainWnd, kTimerReload, 400, nullptr);
        }
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) return (int)msg.wParam;
            HWND settings = SettingsWindow();
            if (settings && IsDialogMessageW(settings, &msg)) continue;  // Tab / Esc in the settings window
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Tick();
    }
}

// ---------------------------------------------------------------------------------------------
// Window / messages
// ---------------------------------------------------------------------------------------------

// Every bundled shader and particles.js preset, so switching doesn't need the ini.
HMENU WallpaperMenu() {
    HMENU sub = CreatePopupMenu();
    S.menuFiles.clear();
    std::wstring current = ToLower(CurrentSource());
    std::wstring group;
    for (auto& w : ListWallpapers()) {
        std::wstring g = w.label.substr(0, w.label.find(L':'));
        std::wstring name = w.label.substr(w.label.find(L':') + 2);
        if (g != group) {
            if (!group.empty()) AppendMenuW(sub, MF_SEPARATOR, 0, nullptr);
            AppendMenuW(sub, MF_STRING | MF_GRAYED, 0, g == L"Shader" ? L"Shaders" : L"Particles");
            group = g;
        }
        bool checked = ToLower(ResolvePath(w.rel)) == current;
        AppendMenuW(sub, MF_STRING | (checked ? MF_CHECKED : 0), ID_WALLPAPER + (UINT)S.menuFiles.size(), name.c_str());
        S.menuFiles.push_back(w.rel);
    }
    return sub;
}

HMENU ProfileMenu() {
    HMENU sub = CreatePopupMenu();
    S.menuProfiles = ListProfiles();
    S.menuProfiles.insert(S.menuProfiles.begin(), L"");
    std::wstring active = ToLower(ActiveProfile());
    for (size_t i = 0; i < S.menuProfiles.size(); ++i) {
        const std::wstring& name = S.menuProfiles[i];
        AppendMenuW(sub, MF_STRING | (ToLower(name) == active ? MF_CHECKED : 0), ID_PROFILE + (UINT)i,
                    name.empty() ? L"Default" : name.c_str());
    }
    AppendMenuW(sub, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(sub, MF_STRING, ID_SETTINGS, L"Save or manage profiles...");
    return sub;
}

void ShowMenu() {
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING | MF_GRAYED, ID_STATUS, S.status.c_str());
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_SETTINGS, L"Settings...");
    SetMenuDefaultItem(m, ID_SETTINGS, FALSE);
    AppendMenuW(m, MF_POPUP, (UINT_PTR)WallpaperMenu(), L"Wallpaper");
    AppendMenuW(m, MF_POPUP, (UINT_PTR)ProfileMenu(), L"Profile");
    AppendMenuW(m, MF_STRING | (S.userPaused ? MF_CHECKED : 0), ID_PAUSE, L"Pause");
    AppendMenuW(m, MF_STRING, ID_EDITFILE, L"Edit settings file");
    AppendMenuW(m, MF_STRING, ID_RELOAD, L"Reload");
    AppendMenuW(m, MF_STRING, ID_FOLDER, L"Open app folder");
    AppendMenuW(m, MF_STRING, ID_DATAFOLDER, L"Open my settings folder");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING | (StartupEnabled() ? MF_CHECKED : 0), ID_STARTUP, L"Start with Windows");
    AppendMenuW(m, MF_STRING | (AllUsersStartupEnabled() ? MF_CHECKED : 0), ID_STARTUPALL, L"Start for all users");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING | MF_GRAYED, ID_VERSION, (std::wstring(kAppName) + L" " + AppVersion()).c_str());
    if (UpdatesSupported())
        AppendMenuW(m, MF_STRING | (UpdateBusy() ? MF_GRAYED : 0), ID_UPDATE, UpdateMenuText().c_str());
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_EXIT, L"Exit");
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(g_mainWnd);
    TrackPopupMenu(m, TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_mainWnd, nullptr);
    PostMessageW(g_mainWnd, WM_NULL, 0, 0);
    DestroyMenu(m);
}

void CALLBACK WinEventProc(HWINEVENTHOOK, DWORD, HWND, LONG idObject, LONG, DWORD, DWORD) {
    if (idObject == OBJID_WINDOW) UpdatePause();
}

LRESULT CALLBACK MainProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == S.taskbarCreated && msg) {  // Explorer restarted: our windows died with it
        AddTray();
        Teardown();
        SetTimer(h, kTimerRebuild, 1500, nullptr);
        return 0;
    }
    switch (msg) {
    case WM_TRAY:
        if (l == WM_RBUTTONUP || l == WM_CONTEXTMENU) ShowMenu();
        else if (l == WM_LBUTTONDBLCLK) ShowSettings();
        return 0;

    case WM_COMMAND:
        if (LOWORD(w) >= ID_PROFILE && LOWORD(w) < ID_PROFILE + S.menuProfiles.size()) {
            SetActiveProfile(S.menuProfiles[LOWORD(w) - ID_PROFILE]);
            ReloadSources();
            return 0;
        }
        if (LOWORD(w) >= ID_WALLPAPER && LOWORD(w) < ID_WALLPAPER + S.menuFiles.size()) {
            WritePrivateProfileStringW(L"default", L"source", S.menuFiles[LOWORD(w) - ID_WALLPAPER].c_str(), ConfigPath().c_str());
            ReloadSources();
            return 0;
        }
        switch (LOWORD(w)) {
        case ID_PAUSE:
            S.userPaused = !S.userPaused;
            UpdatePause();
            break;
        case ID_SETTINGS: ShowSettings(); break;
        case ID_EDITFILE:
            ShellExecuteW(nullptr, L"open", L"notepad.exe", (L"\"" + ConfigPath() + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
            break;
        case ID_RELOAD: Build(); break;
        case ID_FOLDER: ShellExecuteW(nullptr, L"open", ExeDir().c_str(), nullptr, nullptr, SW_SHOWNORMAL); break;
        case ID_DATAFOLDER: ShellExecuteW(nullptr, L"open", DataDir().c_str(), nullptr, nullptr, SW_SHOWNORMAL); break;
        case ID_STARTUP: SetStartup(!StartupEnabled()); break;
        case ID_STARTUPALL: SetAllUsersStartup(!AllUsersStartupEnabled(), h); break;
        case ID_UPDATE: UpdateMenuCommand(h); break;
        case ID_EXIT: DestroyWindow(h); break;
        }
        return 0;

    case WM_TIMER:
        if (w == kTimerPoll) {
            if (!S.screens.empty() && !IsWindow(S.host.parent)) {
                Teardown();
                SetTimer(h, kTimerRebuild, 1500, nullptr);
            } else {
                UpdatePause();
                // A downloaded update installs (and restarts the app) once nothing is in the way.
                if (UpdateWaiting() && !SettingsWindow() && !Gaming()) InstallStagedUpdate(h, false);
            }
        } else if (w == kTimerRebuild) {
            KillTimer(h, w);
            Build();
        } else if (w == kTimerReload) {
            ReloadSources();
        } else if (w == kTimerUpdate) {
            SetTimer(h, kTimerUpdate, kUpdateCheckEvery, nullptr);
            if (AutoUpdateEnabled() && !UpdateWaiting()) {
                if (Gaming()) SetTimer(h, kTimerUpdate, kUpdateRetry, nullptr);
                else StartUpdateCheck(false);
            }
        }
        return 0;

    case WM_DISPLAYCHANGE:
        SetTimer(h, kTimerRebuild, 800, nullptr);
        return 0;

    case WM_SETTINGCHANGE:
        if (w == SPI_SETWORKAREA) SetTimer(h, kTimerRebuild, 800, nullptr);
        return 0;

    case WM_POWERBROADCAST:
        if (w == PBT_POWERSETTINGCHANGE) {
            auto* p = (POWERBROADCAST_SETTING*)l;
            if (p->PowerSetting == kGuidDisplayState) S.displayOff = *(DWORD*)p->Data == 0;
            UpdatePause();
        } else if (w == PBT_APMRESUMEAUTOMATIC) {
            UpdatePause();
        }
        return TRUE;

    case WM_WTSSESSION_CHANGE:
        if (w == WTS_SESSION_LOCK || w == WTS_CONSOLE_DISCONNECT) S.locked = true;
        else if (w == WTS_SESSION_UNLOCK || w == WTS_CONSOLE_CONNECT) S.locked = false;
        UpdatePause();
        return 0;

    case WM_APP_UPDATE:
        OnUpdateCheckDone(SettingsWindow() ? SettingsWindow() : h);  // dialogs in front of the settings window
        RefreshUpdateButton();
        if (S.paused) TrimWorkingSet();
        return 0;

    case WM_APP_VIDEO: {
        auto* src = (Source*)l;
        auto it = std::find_if(S.sources.begin(), S.sources.end(), [&](auto& p) { return p.get() == src; });
        if (it == S.sources.end()) return 0;  // already torn down
        std::wstring err;
        if (src->OnVideoEvent((DWORD)w, err))
            for (auto& s : S.screens)
                if (s->src == src) s->needsDraw = true;
        if (!err.empty()) {
            Log(L"%s: %s", src->key.c_str(), err.c_str());
            ShowBalloon(L"Couldn't play " + FileName(src->key), err);
        }
        return 0;
    }

    case WM_DESTROY:
        Teardown();
        RefreshDesktop(S.host);
        Shell_NotifyIconW(NIM_DELETE, &S.nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

// Dark right-click menus to match the settings window. These uxtheme exports are undocumented
// but stable since Windows 10 1903; if they're missing, menus just stay light.
void UseDarkMenus() {
    HMODULE ux = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!ux) return;
    using SetPreferredAppMode = int(WINAPI*)(int);
    using FlushMenuThemes = void(WINAPI*)();
    if (auto set = (SetPreferredAppMode)GetProcAddress(ux, MAKEINTRESOURCEA(135))) set(2 /* force dark */);
    if (auto flush = (FlushMenuThemes)GetProcAddress(ux, MAKEINTRESOURCEA(136))) flush();
}

void LowerPriority() {
    // Let anything else on the machine, games especially, take the CPU and GPU first.
    SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
    PROCESS_POWER_THROTTLING_STATE eco{PROCESS_POWER_THROTTLING_CURRENT_VERSION, PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
                                       PROCESS_POWER_THROTTLING_EXECUTION_SPEED};
    SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &eco, sizeof(eco));
    using SetGpuClass = LONG(APIENTRY*)(HANDLE, INT);
    if (auto fn = (SetGpuClass)GetProcAddress(GetModuleHandleW(L"gdi32.dll"), "D3DKMTSetProcessSchedulingPriorityClass"))
        fn(GetCurrentProcess(), 1 /* D3DKMT_SCHEDULINGPRIORITYCLASS_BELOW_NORMAL */);
}

}  // namespace

// Start with Windows. The Run key is the classic way, but Explorer holds Run entries back for a
// while after sign-in. A Task Scheduler sign-in task starts us right away instead, so the
// wallpaper is up as the desktop appears. The Run key stays as the fallback.
//
// Each user has their own task, "LiteWallpaper (<user>)". An admin can also add one task for
// everyone, "LiteWallpaper (All users)", which fires at every user's sign-in in their own
// session; a user who turned "Start with Windows" off is skipped (the app exits straight away).
namespace {

const wchar_t kLegacyTaskName[] = L"LiteWallpaper";  // older builds: one name shared by all users
const wchar_t kAllUsersTask[] = L"LiteWallpaper (All users)";
const wchar_t kUsersGroupSid[] = L"S-1-5-32-545";     // BUILTIN\Users: everyone who can sign in

struct Bstr {
    BSTR b;
    explicit Bstr(const wchar_t* s) : b(SysAllocString(s)) {}
    ~Bstr() { SysFreeString(b); }
    operator BSTR() const { return b; }
};

struct Variant {
    VARIANT v;
    Variant() { VariantInit(&v); }
    explicit Variant(const wchar_t* s) {
        VariantInit(&v);
        v.vt = VT_BSTR;
        v.bstrVal = SysAllocString(s);
    }
    ~Variant() { VariantClear(&v); }
    operator VARIANT() const { return v; }
};

std::wstring EnvVar(const wchar_t* name) {
    wchar_t buf[256] = L"";
    GetEnvironmentVariableW(name, buf, ARRAYSIZE(buf));
    return buf;
}

std::wstring Account() { return EnvVar(L"USERDOMAIN") + L"\\" + EnvVar(L"USERNAME"); }
std::wstring UserTaskName() { return std::wstring(kAppName) + L" (" + EnvVar(L"USERNAME") + L")"; }

std::wstring OwnExe() {
    wchar_t exe[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
    return std::wstring(exe, n);
}

bool ConnectTasks(ComPtr<ITaskService>& svc, ComPtr<ITaskFolder>& root) {
    if (FAILED(CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&svc)))) return false;
    VARIANT none;
    VariantInit(&none);
    return SUCCEEDED(svc->Connect(none, none, none, none)) && SUCCEEDED(svc->GetFolder(Bstr(L"\\"), &root));
}

bool TaskExists(const std::wstring& name) {
    ComPtr<ITaskService> svc;
    ComPtr<ITaskFolder> root;
    ComPtr<IRegisteredTask> task;
    return ConnectTasks(svc, root) && SUCCEEDED(root->GetTask(Bstr(name.c_str()), &task));
}

void DeleteTask(const std::wstring& name) {
    ComPtr<ITaskService> svc;
    ComPtr<ITaskFolder> root;
    if (ConnectTasks(svc, root)) root->DeleteTask(Bstr(name.c_str()), 0);
}

// Registers a sign-in task that runs `exe args`. forAllUsers: fires for every user, in their own
// session and with their own (non-admin) rights; registering it needs admin. Otherwise: only the
// current user's sign-in.
bool CreateSignInTask(const std::wstring& name, const std::wstring& exe, const wchar_t* args, bool forAllUsers) {
    ComPtr<ITaskService> svc;
    ComPtr<ITaskFolder> root;
    ComPtr<ITaskDefinition> task;
    if (!ConnectTasks(svc, root) || FAILED(svc->NewTask(0, &task))) return false;

    ComPtr<IRegistrationInfo> info;
    if (SUCCEEDED(task->get_RegistrationInfo(&info)))
        info->put_Description(Bstr(forAllUsers ? L"Starts the LiteWallpaper animated wallpaper when anyone signs in."
                                               : L"Starts the LiteWallpaper animated wallpaper at sign-in."));

    ComPtr<IPrincipal> principal;
    if (SUCCEEDED(task->get_Principal(&principal))) {
        if (forAllUsers) {
            principal->put_GroupId(Bstr(kUsersGroupSid));
            principal->put_LogonType(TASK_LOGON_GROUP);
        } else {
            principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN);
        }
        principal->put_RunLevel(TASK_RUNLEVEL_LUA);
    }

    ComPtr<ITaskSettings> settings;
    if (SUCCEEDED(task->get_Settings(&settings))) {
        settings->put_StartWhenAvailable(VARIANT_TRUE);
        settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE);
        settings->put_StopIfGoingOnBatteries(VARIANT_FALSE);
        settings->put_ExecutionTimeLimit(Bstr(L"PT0S"));  // never stop it (the default is 3 days)
        // All users: two people signed in at once each need their own copy running.
        settings->put_MultipleInstances(forAllUsers ? TASK_INSTANCES_PARALLEL : TASK_INSTANCES_IGNORE_NEW);
        settings->put_Priority(4);  // start promptly; the app lowers its own priority once running
        ComPtr<IIdleSettings> idle;
        if (SUCCEEDED(settings->get_IdleSettings(&idle))) idle->put_StopOnIdleEnd(VARIANT_FALSE);
    }

    ComPtr<ITriggerCollection> triggers;
    ComPtr<ITrigger> trigger;
    ComPtr<ILogonTrigger> logon;
    if (FAILED(task->get_Triggers(&triggers)) || FAILED(triggers->Create(TASK_TRIGGER_LOGON, &trigger)) ||
        FAILED(trigger.As(&logon)))
        return false;
    if (!forAllUsers) logon->put_UserId(Bstr(Account().c_str()));  // only this user's sign-in, no delay

    ComPtr<IActionCollection> actions;
    ComPtr<IAction> action;
    ComPtr<IExecAction> exec;
    if (FAILED(task->get_Actions(&actions)) || FAILED(actions->Create(TASK_ACTION_EXEC, &action)) || FAILED(action.As(&exec)))
        return false;
    exec->put_Path(Bstr(exe.c_str()));
    exec->put_Arguments(Bstr(args));
    exec->put_WorkingDirectory(Bstr(exe.substr(0, exe.find_last_of(L'\\')).c_str()));

    // The all-users task is readable by everyone, so each user's settings window can show it.
    Variant none, group(kUsersGroupSid), sddl(L"D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;AU)");
    ComPtr<IRegisteredTask> registered;
    HRESULT hr = forAllUsers ? root->RegisterTaskDefinition(Bstr(name.c_str()), task.Get(), TASK_CREATE_OR_UPDATE, group,
                                                           none, TASK_LOGON_GROUP, sddl, &registered)
                             : root->RegisterTaskDefinition(Bstr(name.c_str()), task.Get(), TASK_CREATE_OR_UPDATE, none,
                                                           none, TASK_LOGON_INTERACTIVE_TOKEN, none, &registered);
    if (FAILED(hr)) Log(L"Sign-in task \"%s\" could not be created: 0x%08X", name.c_str(), hr);
    return SUCCEEDED(hr);
}

bool RunKeyExists(HKEY hive) {
    return RegGetValueW(hive, kRunKey, kAppName, RRF_RT_REG_SZ, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
}

bool SetRunKey(HKEY hive, const std::wstring& exe, const wchar_t* args) {
    std::wstring cmd = L"\"" + exe + L"\" " + args;
    return RegSetKeyValueW(hive, kRunKey, kAppName, REG_SZ, cmd.c_str(), (DWORD)((cmd.size() + 1) * sizeof(wchar_t))) ==
           ERROR_SUCCESS;
}

// Older builds named every user's task just "LiteWallpaper", so a second user's task would
// overwrite the first one's. Move ours to the per-user name; leave anyone else's alone.
void MigrateLegacyTask() {
    static bool done = false;
    if (done) return;
    done = true;
    ComPtr<ITaskService> svc;
    ComPtr<ITaskFolder> root;
    ComPtr<IRegisteredTask> task;
    ComPtr<ITaskDefinition> def;
    ComPtr<ITriggerCollection> triggers;
    ComPtr<ITrigger> trigger;
    ComPtr<ILogonTrigger> logon;
    if (!ConnectTasks(svc, root) || FAILED(root->GetTask(Bstr(kLegacyTaskName), &task)) || FAILED(task->get_Definition(&def)) ||
        FAILED(def->get_Triggers(&triggers)) || FAILED(triggers->get_Item(1, &trigger)) || FAILED(trigger.As(&logon)))
        return;
    BSTR user = nullptr;
    bool mine = SUCCEEDED(logon->get_UserId(&user)) && user && !_wcsicmp(user, Account().c_str());
    SysFreeString(user);
    if (mine && CreateSignInTask(UserTaskName(), OwnExe(), L"--autostart", false)) root->DeleteTask(Bstr(kLegacyTaskName), 0);
}

bool IsElevated() {
    HANDLE token;
    TOKEN_ELEVATION e{};
    DWORD size;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
    bool ok = GetTokenInformation(token, TokenElevation, &e, sizeof(e), &size) && e.TokenIsElevated;
    CloseHandle(token);
    return ok;
}

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
    PWSTR p = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p))) out = p;
    CoTaskMemFree(p);
    return out;
}

// Other users can't open files inside someone's user profile folder.
bool InUserProfiles(const std::wstring& path) {
    std::wstring profiles = ToLower(KnownFolder(FOLDERID_UserProfiles)) + L"\\";
    return profiles.size() > 1 && ToLower(path).rfind(profiles, 0) == 0;
}

std::wstring SharedInstallDir() { return KnownFolder(FOLDERID_ProgramFiles) + L"\\" + kAppName; }

void CopyTree(const std::wstring& from, const std::wstring& to) {
    CreateDirectoryW(to.c_str(), nullptr);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((from + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        std::wstring src = from + L"\\" + fd.cFileName, dst = to + L"\\" + fd.cFileName;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) CopyTree(src, dst);
        else CopyFileW(src.c_str(), dst.c_str(), FALSE);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

// Runs elevated. Copies the app and its bundled wallpapers into Program Files so every user can
// reach them, and returns the installed exe ("" on failure). An exe that's in use there (someone
// signed in is running it) is kept as it is.
std::wstring InstallShared() {
    std::wstring dir = SharedInstallDir(), exe = dir + L"\\" + kAppName + L".exe";
    CreateDirectoryW(dir.c_str(), nullptr);
    if (!CopyFileW(OwnExe().c_str(), exe.c_str(), FALSE) && GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        Log(L"Could not copy the app to %s: %u", dir.c_str(), GetLastError());
        return L"";
    }
    CopyTree(ExeDir() + L"\\shaders", dir + L"\\shaders");
    CopyTree(ExeDir() + L"\\particles", dir + L"\\particles");
    return exe;
}

// Runs elevated: LiteWallpaper.exe --all-users-startup on|off ["template.ini"].
// The template becomes the starting settings for users who haven't run the app yet.
int AllUsersStartupCommand(bool enable, const std::wstring& templateIni) {
    if (!enable) {
        DeleteTask(kAllUsersTask);
        RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, kRunKey, kAppName);
        return 0;
    }
    std::wstring exe = InUserProfiles(OwnExe()) ? InstallShared() : OwnExe();
    if (exe.empty()) return 2;
    std::wstring ini = exe.substr(0, exe.find_last_of(L'\\')) + L"\\wallpaper.ini";
    if (!templateIni.empty() && CopyFileW(templateIni.c_str(), ini.c_str(), TRUE))
        WritePrivateProfileStringW(L"app", nullptr, nullptr, ini.c_str());  // profile pointer, autostart: per user
    if (CreateSignInTask(kAllUsersTask, exe, L"--autostart-all", true)) {
        RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, kRunKey, kAppName);  // the task replaces the slower Run entry
        return 0;
    }
    return SetRunKey(HKEY_LOCAL_MACHINE, exe, L"--autostart-all") ? 0 : 1;
}

}  // namespace

bool AllUsersStartupEnabled() { return TaskExists(kAllUsersTask) || RunKeyExists(HKEY_LOCAL_MACHINE); }

bool StartupEnabled() {
    MigrateLegacyTask();
    if (AllUsersStartupEnabled()) return UserWantsAutostart();
    return TaskExists(UserTaskName()) || RunKeyExists(HKEY_CURRENT_USER);
}

void SetStartup(bool enable) {
    MigrateLegacyTask();
    SetUserAutostart(enable);
    if (enable && AllUsersStartupEnabled()) return;  // the all-users task already starts us
    if (enable && CreateSignInTask(UserTaskName(), OwnExe(), L"--autostart", false)) {
        RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kAppName);  // the task replaces the slower Run entry
    } else if (enable) {
        SetRunKey(HKEY_CURRENT_USER, OwnExe(), L"--autostart");
    } else {
        DeleteTask(UserTaskName());
        RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kAppName);
    }
}

bool SetAllUsersStartup(bool enable, HWND owner) {
    MigrateLegacyTask();
    if (enable && InUserProfiles(OwnExe())) {
        std::wstring q = L"Other people on this PC can't open files in your user folder, so LiteWallpaper will be "
                         L"copied to " + SharedInstallDir() + L" and started from there.\n\nEveryone keeps their own "
                         L"wallpaper and settings. People who haven't used LiteWallpaper yet start with your current "
                         L"setup.";
        if (MessageBoxW(owner, q.c_str(), L"Start for all users", MB_OKCANCEL | MB_ICONINFORMATION) != IDOK) return false;
    }
    std::wstring args = std::wstring(L"--all-users-startup ") + (enable ? L"on" : L"off") + L" \"" + ConfigPath() + L"\"";
    DWORD code = 1;
    if (IsElevated()) {
        code = (DWORD)AllUsersStartupCommand(enable, ConfigPath());
    } else {
        std::wstring exe = OwnExe();
        SHELLEXECUTEINFOW sei{sizeof(sei)};
        sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        sei.hwnd = owner;
        sei.lpVerb = L"runas";
        sei.lpFile = exe.c_str();
        sei.lpParameters = args.c_str();
        sei.nShow = SW_HIDE;
        if (!ShellExecuteExW(&sei)) return false;  // the admin prompt was cancelled
        if (sei.hProcess) {
            WaitForSingleObject(sei.hProcess, 60000);
            GetExitCodeProcess(sei.hProcess, &code);
            CloseHandle(sei.hProcess);
        }
    }
    if (code != 0) {
        MessageBoxW(owner, enable ? L"Couldn't set LiteWallpaper to start for all users." : L"Couldn't turn off starting for all users.",
                    L"Start for all users", MB_OK | MB_ICONWARNING);
        return false;
    }
    return true;
}

std::vector<WallpaperEntry> ListWallpapers() {
    std::vector<WallpaperEntry> out;
    auto group = [&](const wchar_t* folder, const wchar_t* pattern, const wchar_t* label) {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW((ExeDir() + L"\\" + folder + L"\\" + pattern).c_str(), &fd);
        if (h == INVALID_HANDLE_VALUE) return;
        do {
            std::wstring name = fd.cFileName;
            out.push_back({std::wstring(folder) + L"\\" + fd.cFileName, std::wstring(label) + L": " + name.substr(0, name.find_last_of(L'.'))});
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    };
    group(L"shaders", L"*.hlsl", L"Shader");
    group(L"particles", L"*.json", L"Particles");
    return out;
}

std::wstring CurrentSource() { return ResolvePath(S.cfg.def.source); }

void RequestReload() { SetTimer(g_mainWnd, kTimerReload, 150, nullptr); }

HICON AppIcon(bool large) {
    static HICON big = LoadAppIcon(true);
    return large ? big : S.nid.hIcon;
}

void ShowNotice(const std::wstring& title, const std::wstring& text) { ShowBalloon(title, text, NIIF_INFO); }

namespace {

// --exit / --uninstall: asks the running copy to close and waits until it has, so an installer can
// replace its files straight after. onlyThisCopy: leave a copy that runs from somewhere else alone.
void ExitRunningCopy(bool onlyThisCopy = false) {
    HWND other = FindWindowW(kMainClass, nullptr);
    if (!other) return;
    DWORD pid = 0;
    GetWindowThreadProcessId(other, &pid);
    HANDLE proc = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (onlyThisCopy) {
        wchar_t path[MAX_PATH * 2] = L"";
        DWORD size = ARRAYSIZE(path);
        if (!proc || !QueryFullProcessImageNameW(proc, 0, path, &size) || _wcsicmp(path, OwnExe().c_str())) {
            if (proc) CloseHandle(proc);
            return;
        }
    }
    PostMessageW(other, WM_COMMAND, ID_EXIT, 0);
    if (proc) {
        WaitForSingleObject(proc, 10000);
        CloseHandle(proc);
    }
}

// The exe a sign-in task starts, or "" when there's no such task.
std::wstring TaskExe(const std::wstring& name) {
    ComPtr<ITaskService> svc;
    ComPtr<ITaskFolder> root;
    ComPtr<IRegisteredTask> task;
    ComPtr<ITaskDefinition> def;
    ComPtr<IActionCollection> actions;
    ComPtr<IAction> action;
    ComPtr<IExecAction> exec;
    BSTR path = nullptr;
    if (!ConnectTasks(svc, root) || FAILED(root->GetTask(Bstr(name.c_str()), &task)) || FAILED(task->get_Definition(&def)) ||
        FAILED(def->get_Actions(&actions)) || FAILED(actions->get_Item(1, &action)) || FAILED(action.As(&exec)) ||
        FAILED(exec->get_Path(&path)) || !path)
        return L"";
    std::wstring out = path;
    SysFreeString(path);
    return out;
}

// --uninstall, run by the uninstaller: closes this copy and removes this user's "Start with Windows"
// entries if they start this copy (not a portable one elsewhere).
int UninstallCommand() {
    ExitRunningCopy(true);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    std::wstring exe = OwnExe();
    if (!_wcsicmp(TaskExe(UserTaskName()).c_str(), exe.c_str())) DeleteTask(UserTaskName());
    wchar_t run[MAX_PATH * 2 + 32] = L"";
    DWORD size = sizeof(run);
    if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, kAppName, RRF_RT_REG_SZ, nullptr, run, &size) == ERROR_SUCCESS &&
        ToLower(run).find(ToLower(exe)) != std::wstring::npos)
        RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kAppName);
    CoUninitialize();
    return 0;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR cmdLine, int) {
    // Elevated helper started by SetAllUsersStartup: do that one job and leave.
    int argc = 0;
    PWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv && argc >= 3 && !wcscmp(argv[1], L"--all-users-startup")) {
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        int code = AllUsersStartupCommand(!wcscmp(argv[2], L"on"), argc >= 4 ? argv[3] : L"");
        CoUninitialize();
        LocalFree(argv);
        return code;
    }
    // Elevated helper started by the updater when the app folder needs admin rights to write.
    if (argv && argc >= 6 && !wcscmp(argv[1], L"--install-update")) {
        int code = InstallUpdateCommand(argv[2], argv[3], argv[4], argv[5]);
        LocalFree(argv);
        return code;
    }
    // Run by the uninstaller: close a running copy and drop this user's "Start with Windows" entries.
    if (argv && argc >= 2 && !wcscmp(argv[1], L"--uninstall")) {
        LocalFree(argv);
        return UninstallCommand();
    }
    // Started by the updater: let the old version exit first, then take over.
    const bool updated = argv && argc >= 3 && !wcscmp(argv[1], L"--updated");
    if (updated) FinishUpdate((DWORD)wcstoul(argv[2], nullptr, 10));
    LocalFree(argv);

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    LoadActiveProfile();
    // Started at sign-in (--autostart: the user's own task; --autostart-all: the task for everyone).
    const bool autostart = wcsstr(cmdLine, L"--autostart") != nullptr;
    if (wcsstr(cmdLine, L"--autostart-all") && !UserWantsAutostart()) return 0;

    HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Local\\LiteWallpaper.SingleInstance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (wcsstr(cmdLine, L"--exit")) {
            ExitRunningCopy();
        } else if (HWND other = FindWindowW(kMainClass, nullptr); other && !autostart) {
            PostMessageW(other, WM_COMMAND, ID_SETTINGS, 0);  // a second sign-in task finding us already up stays quiet
        }
        return 0;
    }
    if (wcsstr(cmdLine, L"--exit")) return 0;
    S.diag = g_diag = wcsstr(cmdLine, L"--diag") != nullptr;

    LowerPriority();
    UseDarkMenus();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    WNDCLASSEXW wc{sizeof(wc)};
    wc.lpfnWndProc = MainProc;
    wc.hInstance = inst;
    wc.lpszClassName = kMainClass;
    RegisterClassExW(&wc);
    g_mainWnd = CreateWindowExW(WS_EX_TOOLWINDOW, kMainClass, kAppName, WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
    if (!g_mainWnd) return 1;

    S.taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    AddTray();

    S.timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (!S.timer) S.timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
    for (int i = 0; i < 2; ++i)
        S.dirWatch[i] = FindFirstChangeNotificationW((i ? DataDir() : ExeDir()).c_str(), TRUE,
                                                     FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME);

    const DWORD hookFlags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
    HWINEVENTHOOK hooks[] = {
        SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, WinEventProc, 0, 0, hookFlags),
        SetWinEventHook(EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MOVESIZEEND, nullptr, WinEventProc, 0, 0, hookFlags),
        SetWinEventHook(EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND, nullptr, WinEventProc, 0, 0, hookFlags),
    };
    HPOWERNOTIFY power[] = {
        RegisterPowerSettingNotification(g_mainWnd, &kGuidDisplayState, DEVICE_NOTIFY_WINDOW_HANDLE),
        RegisterPowerSettingNotification(g_mainWnd, &kGuidAcDcSource, DEVICE_NOTIFY_WINDOW_HANDLE),
    };
    WTSRegisterSessionNotification(g_mainWnd, NOTIFY_FOR_THIS_SESSION);

    Build();
    SetTimer(g_mainWnd, kTimerPoll, 1000, nullptr);
    if (UpdatesSupported()) {
        CleanUpOldUpdate();
        SetTimer(g_mainWnd, kTimerUpdate, kFirstUpdateCheck, nullptr);
        if (updated) ShowUpdatedNotice();
    }
    if (wcsstr(cmdLine, L"--settings")) ShowSettings();
    int code = Run();

    WTSUnRegisterSessionNotification(g_mainWnd);
    for (auto p : power)
        if (p) UnregisterPowerSettingNotification(p);
    for (auto hk : hooks)
        if (hk) UnhookWinEvent(hk);
    for (HANDLE w : S.dirWatch)
        if (w != INVALID_HANDLE_VALUE) FindCloseChangeNotification(w);
    S.gpu.Reset();
    CoUninitialize();
    ReleaseMutex(mutex);
    return code;
}
