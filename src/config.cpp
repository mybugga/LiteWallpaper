#include "app.h"
#include <shlobj.h>
#include <algorithm>
#include <cstdarg>
#include <cwctype>

static const wchar_t kDefaultIni[] =
LR"(; LiteWallpaper settings. Changes apply as soon as you save this file.
; Each Windows user has their own copy of this file. Paths can be absolute or relative to
; the LiteWallpaper program folder. Environment variables like %USERPROFILE% work.

[general]
; Max frames per second for shader wallpapers. Lower = lighter.
fps = 30
; How often a video is checked for a new frame. It only redraws when the frame actually changes.
video_fps = 60
; Stop completely while any app or game is fullscreen (exclusive or borderless).
pause_on_fullscreen = 1
; Stop drawing a monitor while windows cover it (one maximized window, or several snapped ones).
pause_when_covered = 1
; Stop while running on battery.
pause_on_battery = 1
; Stop while any of these programs are running, even windowed. Comma separated exe names.
; Example: pause_apps = cs2.exe, valorant.exe, eldenring.exe
pause_apps =

[default]
; A shader (.hlsl), a particles.js config (.json), a video (.mp4 .mkv .webm .mov .wmv .avi),
; a GIF, or an image (.png .jpg .bmp). The tray icon's Wallpaper menu switches between the bundled ones.
source = shaders\aurora.hlsl
; How images and videos fill the screen: cover (crop to fill), contain (letterbox), stretch.
fit = cover
; Render resolution for shaders. 0.5 = half resolution, upscaled: 4x less GPU work.
scale = 0.5

; Give a monitor its own wallpaper. Monitors are numbered left to right, starting at 1.
; Anything left out falls back to [default].
;[monitor2]
;source = C:\Videos\loop.mp4
)";

std::wstring ExeDir() {
    wchar_t buf[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, buf, ARRAYSIZE(buf));
    std::wstring p(buf, n);
    return p.substr(0, p.find_last_of(L"\\/"));
}

static std::wstring KnownFolder(REFKNOWNFOLDERID id) {
    PWSTR p = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p))) out = p;
    CoTaskMemFree(p);
    return out;
}

static void SeedFrom(const std::wstring& from, const std::wstring& to);

// Every Windows user keeps their own settings, profiles and log in %APPDATA%\LiteWallpaper, so
// one copy of the app (say in Program Files) serves everyone. A wallpaper.ini next to the exe is
// only a starting point: it's copied in the first time a user runs the app.
std::wstring DataDir() {
    static const std::wstring dir = [] {
        std::wstring base = KnownFolder(FOLDERID_RoamingAppData);
        if (base.empty()) return ExeDir();
        std::wstring d = base + L"\\LiteWallpaper";
        if (GetFileAttributesW(d.c_str()) == INVALID_FILE_ATTRIBUTES) {
            CreateDirectoryW(d.c_str(), nullptr);
            SeedFrom(ExeDir(), d);
        }
        return d;
    }();
    return dir;
}

static void SeedFrom(const std::wstring& from, const std::wstring& to) {
    std::wstring ini = to + L"\\wallpaper.ini";
    if (!CopyFileW((from + L"\\wallpaper.ini").c_str(), ini.c_str(), TRUE)) return;
    WritePrivateProfileStringW(L"app", L"autostart", nullptr, ini.c_str());  // that choice was someone else's
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((from + L"\\profiles\\*.ini").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    CreateDirectoryW((to + L"\\profiles").c_str(), nullptr);
    do CopyFileW((from + L"\\profiles\\" + fd.cFileName).c_str(), (to + L"\\profiles\\" + fd.cFileName).c_str(), TRUE);
    while (FindNextFileW(h, &fd));
    FindClose(h);
}

std::wstring ToLower(std::wstring s) {
    for (auto& c : s) c = (wchar_t)towlower(c);
    return s;
}

std::wstring FileName(const std::wstring& path) {
    size_t i = path.find_last_of(L"\\/");
    return i == std::wstring::npos ? path : path.substr(i + 1);
}

std::wstring Utf8ToWide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), w.data(), n);
    return w;
}

std::string WideToUtf8(const std::wstring& w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring OverrideSection(const std::wstring& fullPath) {
    std::wstring p = ToLower(fullPath), dir = ToLower(ExeDir()) + L"\\";
    if (p.rfind(dir, 0) == 0) p = p.substr(dir.size());
    return L"override:" + p;
}

float IniFloat(const std::wstring& section, const wchar_t* key, float def) {
    wchar_t buf[64];
    GetPrivateProfileStringW(section.c_str(), key, L"", buf, ARRAYSIZE(buf), ConfigPath().c_str());
    return buf[0] ? (float)_wtof(buf) : def;
}

static std::wstring Trim(const std::wstring& s) {
    size_t a = s.find_first_not_of(L" \t\"");
    if (a == std::wstring::npos) return L"";
    size_t b = s.find_last_not_of(L" \t\"");
    return s.substr(a, b - a + 1);
}

std::wstring ResolvePath(const std::wstring& raw) {
    std::wstring p = Trim(raw);
    if (p.empty()) return p;
    wchar_t expanded[MAX_PATH * 2];
    if (ExpandEnvironmentStringsW(p.c_str(), expanded, ARRAYSIZE(expanded))) p = expanded;
    bool absolute = (p.size() > 1 && p[1] == L':') || (p.size() > 1 && p[0] == L'\\' && p[1] == L'\\');
    if (!absolute) p = ExeDir() + L"\\" + p;
    wchar_t full[MAX_PATH * 2];
    if (GetFullPathNameW(p.c_str(), ARRAYSIZE(full), full, nullptr)) p = full;
    return p;
}

void Log(const wchar_t* fmt, ...) {
    wchar_t msg[2048];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(msg, _TRUNCATE, fmt, ap);
    va_end(ap);

    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t line[2200];
    swprintf_s(line, L"[%02d:%02d:%02d] %s\r\n", st.wHour, st.wMinute, st.wSecond, msg);
    OutputDebugStringW(line);

    std::wstring path = DataDir() + L"\\LiteWallpaper.log";
    WIN32_FILE_ATTRIBUTE_DATA fa;
    bool tooBig = GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fa) && fa.nFileSizeLow > 512 * 1024;
    HANDLE f = CreateFileW(path.c_str(), tooBig ? GENERIC_WRITE : FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                           tooBig ? CREATE_ALWAYS : OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    char utf8[4400];
    int len = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8, sizeof(utf8), nullptr, nullptr);
    DWORD written;
    if (len > 1) WriteFile(f, utf8, len - 1, &written, nullptr);
    CloseHandle(f);
}

// ---- profiles ----
// The user's wallpaper.ini is the "Default" profile. Other profiles are full copies in
// profiles\<name>.ini. Which one is active is remembered in wallpaper.ini under [app] profile=,
// and is resolved before anything else reads a setting.

static std::wstring g_configPath;

static std::wstring BaseConfigPath() { return DataDir() + L"\\wallpaper.ini"; }
static std::wstring ProfilePath(const std::wstring& name) { return DataDir() + L"\\profiles\\" + name + L".ini"; }

std::wstring ActiveProfile() {
    wchar_t buf[128];
    GetPrivateProfileStringW(L"app", L"profile", L"", buf, ARRAYSIZE(buf), BaseConfigPath().c_str());
    std::wstring name = buf;
    if (!name.empty() && GetFileAttributesW(ProfilePath(name).c_str()) == INVALID_FILE_ATTRIBUTES) name.clear();
    return name;
}

void LoadActiveProfile() {
    std::wstring name = ActiveProfile();
    g_configPath = name.empty() ? BaseConfigPath() : ProfilePath(name);
}

std::wstring ConfigPath() {
    if (g_configPath.empty()) LoadActiveProfile();
    return g_configPath;
}

void SetActiveProfile(const std::wstring& name) {
    WritePrivateProfileStringW(L"app", L"profile", name.empty() ? nullptr : name.c_str(), BaseConfigPath().c_str());
    LoadActiveProfile();
}

std::vector<std::wstring> ListProfiles() {
    std::vector<std::wstring> out;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((DataDir() + L"\\profiles\\*.ini").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do {
        std::wstring n = fd.cFileName;
        out.push_back(n.substr(0, n.size() - 4));
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    std::sort(out.begin(), out.end(), [](auto& a, auto& b) { return ToLower(a) < ToLower(b); });
    return out;
}

bool SaveProfileAs(const std::wstring& rawName, std::wstring& err) {
    std::wstring name = Trim(rawName);
    for (auto& c : name)
        if (wcschr(L"\\/:*?\"<>|", c)) c = L'_';
    if (name.empty() || ToLower(name) == L"default") {
        err = L"Pick a different name.";
        return false;
    }
    if (GetFileAttributesW(ProfilePath(name).c_str()) != INVALID_FILE_ATTRIBUTES) {
        err = L"A profile with that name already exists.";
        return false;
    }
    CreateDirectoryW((DataDir() + L"\\profiles").c_str(), nullptr);
    if (!CopyFileW(ConfigPath().c_str(), ProfilePath(name).c_str(), TRUE)) {
        err = L"Could not create the profile file.";
        return false;
    }
    WritePrivateProfileStringW(L"app", nullptr, nullptr, ProfilePath(name).c_str());  // pointer lives in wallpaper.ini only
    SetActiveProfile(name);
    return true;
}

void DeleteProfile(const std::wstring& name) {
    if (name.empty()) return;
    if (ToLower(name) == ToLower(ActiveProfile())) SetActiveProfile(L"");
    DeleteFileW(ProfilePath(name).c_str());
}

// [app] autostart=0 in the user's own wallpaper.ini: this user turned "Start with Windows" off,
// so the all-users sign-in task leaves them alone.
bool UserWantsAutostart() {
    return GetPrivateProfileIntW(L"app", L"autostart", 1, BaseConfigPath().c_str()) != 0;
}

void SetUserAutostart(bool on) {
    WritePrivateProfileStringW(L"app", L"autostart", on ? nullptr : L"0", BaseConfigPath().c_str());
}

// [app] auto_update=0: this user installs updates only from the tray's "Check for updates".
bool AutoUpdateEnabled() {
    return GetPrivateProfileIntW(L"app", L"auto_update", 1, BaseConfigPath().c_str()) != 0;
}

void SetAutoUpdate(bool on) {
    WritePrivateProfileStringW(L"app", L"auto_update", on ? nullptr : L"0", BaseConfigPath().c_str());
}

static std::wstring ReadStr(const wchar_t* section, const wchar_t* key, const std::wstring& def) {
    wchar_t buf[1024];
    GetPrivateProfileStringW(section, key, L"\x01", buf, ARRAYSIZE(buf), ConfigPath().c_str());
    if (buf[0] == L'\x01') return def;
    std::wstring v = buf;
    // Strip inline comments ("value ; comment").
    for (size_t i = 1; i < v.size(); ++i) {
        if ((v[i] == L';' || v[i] == L'#') && (v[i - 1] == L' ' || v[i - 1] == L'\t')) {
            v.resize(i);
            break;
        }
    }
    return Trim(v);
}

static int ReadInt(const wchar_t* section, const wchar_t* key, int def) {
    std::wstring v = ReadStr(section, key, L"");
    return v.empty() ? def : _wtoi(v.c_str());
}

static float ReadFloat(const wchar_t* section, const wchar_t* key, float def) {
    std::wstring v = ReadStr(section, key, L"");
    return v.empty() ? def : (float)_wtof(v.c_str());
}

static Fit ParseFit(const std::wstring& v, Fit def) {
    std::wstring s = ToLower(v);
    if (s == L"cover" || s == L"fill") return Fit::Cover;
    if (s == L"contain" || s == L"fit") return Fit::Contain;
    if (s == L"stretch") return Fit::Stretch;
    return def;
}

static ScreenConfig ReadScreen(const wchar_t* section, const ScreenConfig& base) {
    ScreenConfig c;
    c.source = ReadStr(section, L"source", base.source);
    c.fit = ParseFit(ReadStr(section, L"fit", L""), base.fit);
    c.scale = std::clamp(ReadFloat(section, L"scale", base.scale), 0.1f, 1.0f);
    return c;
}

ScreenConfig Config::ForMonitor(int index) const {
    for (auto& [i, c] : perMonitor)
        if (i == index) return c;
    return def;
}

Config LoadConfig() {
    std::wstring path = ConfigPath();
    if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE) {
            // UTF-16 LE with BOM so GetPrivateProfileString reads non-ASCII paths correctly.
            DWORD written;
            WORD bom = 0xFEFF;
            WriteFile(f, &bom, 2, &written, nullptr);
            WriteFile(f, kDefaultIni, (DWORD)(wcslen(kDefaultIni) * sizeof(wchar_t)), &written, nullptr);
            CloseHandle(f);
        }
    }

    Config c;
    c.fps = std::clamp(ReadInt(L"general", L"fps", 30), 1, 240);
    c.videoFps = std::clamp(ReadInt(L"general", L"video_fps", 60), 1, 240);
    c.pauseOnFullscreen = ReadInt(L"general", L"pause_on_fullscreen", 1) != 0;
    c.pauseWhenCovered = ReadInt(L"general", L"pause_when_covered", 1) != 0;
    c.pauseOnBattery = ReadInt(L"general", L"pause_on_battery", 1) != 0;

    std::wstring apps = ReadStr(L"general", L"pause_apps", L"");
    size_t pos = 0;
    while (pos <= apps.size()) {
        size_t end = apps.find(L',', pos);
        if (end == std::wstring::npos) end = apps.size();
        std::wstring name = ToLower(Trim(apps.substr(pos, end - pos)));
        if (!name.empty()) c.pauseApps.push_back(name);
        pos = end + 1;
    }

    ScreenConfig builtin;
    builtin.source = L"shaders\\aurora.hlsl";
    builtin.scale = 0.5f;
    c.def = ReadScreen(L"default", builtin);

    for (int i = 1; i <= 16; ++i) {
        wchar_t section[32];
        swprintf_s(section, L"monitor%d", i);
        wchar_t probe[8];
        if (GetPrivateProfileSectionW(section, probe, ARRAYSIZE(probe), path.c_str()) > 0)
            c.perMonitor.emplace_back(i, ReadScreen(section, c.def));
    }
    return c;
}
