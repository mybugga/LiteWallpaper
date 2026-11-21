// Settings window: plain Win32 controls, created only while open. Every change is written to
// wallpaper.ini straight away and the wallpaper reloads a moment later, so edits show live.
//
// Particles and shader tweaks go into an "[override:<file>]" section rather than the preset file
// itself, so "Reset" can always get back to the original.

#include "app.h"
#include "json.h"
#include <commctrl.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <shellapi.h>
#include <algorithm>
#include <cmath>

namespace {

const wchar_t kClass[] = L"LiteWallpaper.Settings";
constexpr int kClientW = 680, kClientH = 584;  // at 96 dpi
constexpr int kSideW = 150, kTopH = 100, kBottomH = 56, kRowH = 36, kLabelW = 160;

enum : int { IDC_WALLPAPER = 10, IDC_BROWSE, IDC_SECTIONS, IDC_RESET, IDC_OPENFILE, IDC_PROFILE, IDC_SAVEPROFILE,
             IDC_DELPROFILE, IDC_ROW = 1000 };

enum class Store { General, Default, Particle, Shader, Startup, StartupAll, AutoUpdate, None };
enum class Kind { Slider, Check, Color, Combo, Text, File, Button };
enum class Type { Shader, Particles, Picture };

struct Choice {
    const wchar_t* label;
    const char* value;  // stored string
};

struct Row {
    Kind kind;
    const wchar_t* label;
    Store store;
    const char* key;
    const char* def = "0";        // JSON text used when the value isn't set anywhere
    int min = 0, max = 100;       // slider range
    float scale = 1;              // stored value = slider position * scale
    const wchar_t* unit = L"";
    std::vector<Choice> choices;
    const wchar_t* checkLabel = nullptr;  // optional checkbox after the control
    const char* checkKey = nullptr;       // same as key on a color row = "random" toggle
    const char* checkDef = "false";
    const char* on = "true";              // JSON text written by checkboxes
    const char* off = "false";

    HWND ctl = nullptr, value = nullptr, check = nullptr, browse = nullptr, clear = nullptr;
    COLORREF color = 0;
};

struct Section {
    const wchar_t* name;
    std::vector<Row> rows;
};

struct Ui {
    HWND wnd = nullptr;
    HWND profile = nullptr, saveProfile = nullptr, delProfile = nullptr;
    HWND wallpaper = nullptr, browse = nullptr, sections = nullptr, title = nullptr, hint = nullptr;
    HWND reset = nullptr, openFile = nullptr, close = nullptr;
    HFONT font = nullptr, bold = nullptr;
    int dpi = 96;
    Type type = Type::Picture;
    std::wstring source, section;
    Json particles;  // effective particles.js config (preset + overrides)
    std::vector<Section> secs;
    int current = 0;
    std::vector<HWND> page;
    std::vector<WallpaperEntry> entries;
    std::vector<std::wstring> profiles;  // [0] = "" (Default)
    COLORREF custom[16] = {};
} U;

int Px(int v) { return MulDiv(v, U.dpi, 96); }

// ---------------------------------------------------------------------------------------------
// Dark theme. Checkboxes, buttons, sliders and the sidebar are drawn here: Windows' own
// checkboxes and buttons keep black text on a dark background.

namespace Theme {
constexpr COLORREF Bg = RGB(32, 32, 32), Field = RGB(45, 45, 45), Button = RGB(55, 55, 55),
                   ButtonPressed = RGB(40, 40, 40), Border = RGB(80, 80, 80), Selected = RGB(52, 52, 52),
                   Text = RGB(235, 235, 235), Dim = RGB(150, 150, 150), Disabled = RGB(110, 110, 110),
                   Accent = RGB(76, 194, 255), AccentPressed = RGB(60, 160, 215), Track = RGB(95, 95, 95),
                   Thumb = RGB(69, 69, 69);
}

HBRUSH BgBrush() {
    static HBRUSH b = CreateSolidBrush(Theme::Bg);
    return b;
}
HBRUSH FieldBrush() {
    static HBRUSH b = CreateSolidBrush(Theme::Field);
    return b;
}

// Lets standard controls (dropdown lists, scrollbars) use their dark look. Undocumented
// uxtheme export, stable since Windows 10 1809; skipped if missing.
void AllowDark(HWND h) {
    using Fn = BOOL(WINAPI*)(HWND, BOOL);
    static Fn fn = (Fn)GetProcAddress(GetModuleHandleW(L"uxtheme.dll"), MAKEINTRESOURCEA(133));
    if (fn) fn(h, TRUE);
}

void DarkTitleBar(HWND h) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(h, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    AllowDark(h);
}

// Owner-drawn buttons keep their kind and checked state in GWLP_USERDATA.
enum : LONG_PTR { kCheckbox = 1, kButton = 2, kPrimary = 3, kCheckedBit = 0x100 };
int ButtonKind(HWND h) { return (int)(GetWindowLongPtrW(h, GWLP_USERDATA) & 0xF); }
bool Checked(HWND h) { return (GetWindowLongPtrW(h, GWLP_USERDATA) & kCheckedBit) != 0; }
void SetChecked(HWND h, bool on) {
    LONG_PTR v = GetWindowLongPtrW(h, GWLP_USERDATA) & ~kCheckedBit;
    SetWindowLongPtrW(h, GWLP_USERDATA, v | (on ? kCheckedBit : 0));
    InvalidateRect(h, nullptr, FALSE);
}

void FillRound(HDC dc, const RECT& rc, int radius, COLORREF fill, COLORREF border) {
    HBRUSH b = CreateSolidBrush(fill);
    HPEN p = CreatePen(PS_SOLID, 1, border);
    HGDIOBJ ob = SelectObject(dc, b), op = SelectObject(dc, p);
    RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom, radius * 2, radius * 2);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(b);
    DeleteObject(p);
}

void DrawButton(const DRAWITEMSTRUCT* di) {
    HDC dc = di->hDC;
    RECT rc = di->rcItem;
    FillRect(dc, &rc, BgBrush());
    const bool pressed = di->itemState & ODS_SELECTED, disabled = di->itemState & ODS_DISABLED;
    const bool focus = (di->itemState & ODS_FOCUS) && !(di->itemState & ODS_NOFOCUSRECT);
    wchar_t text[128] = L"";
    GetWindowTextW(di->hwndItem, text, ARRAYSIZE(text));
    HGDIOBJ oldFont = SelectObject(dc, (HFONT)SendMessageW(di->hwndItem, WM_GETFONT, 0, 0));
    SetBkMode(dc, TRANSPARENT);

    if (ButtonKind(di->hwndItem) == kCheckbox) {
        const int s = Px(18), cy = (rc.top + rc.bottom) / 2;
        RECT box{rc.left + 1, cy - s / 2, rc.left + 1 + s, cy - s / 2 + s};
        const bool on = Checked(di->hwndItem);
        FillRound(dc, box, Px(4), on ? Theme::Accent : Theme::Field, on ? Theme::Accent : (focus ? Theme::Accent : RGB(140, 140, 140)));
        if (on) {
            HPEN pen = CreatePen(PS_SOLID, std::max(2, Px(2)), RGB(0, 0, 0));
            HGDIOBJ op = SelectObject(dc, pen);
            POINT pts[3] = {{box.left + s * 24 / 100, box.top + s * 52 / 100},
                            {box.left + s * 43 / 100, box.top + s * 70 / 100},
                            {box.left + s * 76 / 100, box.top + s * 32 / 100}};
            Polyline(dc, pts, 3);
            SelectObject(dc, op);
            DeleteObject(pen);
        }
        RECT t = rc;
        t.left = box.right + Px(8);
        SetTextColor(dc, disabled ? Theme::Disabled : Theme::Text);
        DrawTextW(dc, text, -1, &t, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
    } else {
        const bool primary = ButtonKind(di->hwndItem) == kPrimary;
        COLORREF fill = disabled ? Theme::Field
                      : primary  ? (pressed ? Theme::AccentPressed : Theme::Accent)
                                 : (pressed ? Theme::ButtonPressed : Theme::Button);
        COLORREF border = focus ? (primary ? RGB(255, 255, 255) : Theme::Accent) : (primary && !disabled ? fill : Theme::Border);
        FillRound(dc, rc, Px(4), fill, border);
        SetTextColor(dc, disabled ? Theme::Disabled : primary ? RGB(0, 0, 0) : Theme::Text);
        DrawTextW(dc, text, -1, &rc, DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_NOPREFIX);
    }
    SelectObject(dc, oldFont);
}

// Win11-style slider: thin rounded track filled with the accent up to the thumb, round thumb.
LRESULT DrawTrackbar(NMCUSTOMDRAW* cd) {
    if (cd->dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
    if (cd->dwDrawStage != CDDS_ITEMPREPAINT) return CDRF_DODEFAULT;
    HDC dc = cd->hdc;
    RECT thumb{};
    SendMessageW(cd->hdr.hwndFrom, TBM_GETTHUMBRECT, 0, (LPARAM)&thumb);
    const int tx = (thumb.left + thumb.right) / 2, ty = (thumb.top + thumb.bottom) / 2;
    if (cd->dwItemSpec == TBCD_CHANNEL) {
        const int h = std::max(2, Px(4)), cy = (cd->rc.top + cd->rc.bottom) / 2;
        RECT full{cd->rc.left, cy - h / 2, cd->rc.right, cy - h / 2 + h};
        FillRound(dc, full, h / 2, Theme::Track, Theme::Track);
        RECT done = full;
        done.right = tx;
        if (done.right > done.left) FillRound(dc, done, h / 2, Theme::Accent, Theme::Accent);
        return CDRF_SKIPDEFAULT;
    }
    if (cd->dwItemSpec == TBCD_THUMB) {
        const int r = Px(9), inner = Px(5);
        HBRUSH outer = CreateSolidBrush(Theme::Thumb), dot = CreateSolidBrush(Theme::Accent);
        HPEN ring = CreatePen(PS_SOLID, 1, RGB(90, 90, 90)), none = CreatePen(PS_SOLID, 1, Theme::Accent);
        HGDIOBJ ob = SelectObject(dc, outer), op = SelectObject(dc, ring);
        Ellipse(dc, tx - r, ty - r, tx + r + 1, ty + r + 1);
        SelectObject(dc, dot);
        SelectObject(dc, none);
        Ellipse(dc, tx - inner, ty - inner, tx + inner + 1, ty + inner + 1);
        SelectObject(dc, ob);
        SelectObject(dc, op);
        DeleteObject(outer);
        DeleteObject(dot);
        DeleteObject(ring);
        DeleteObject(none);
        return CDRF_SKIPDEFAULT;
    }
    return CDRF_SKIPDEFAULT;  // no tick marks
}

void DrawComboItem(const DRAWITEMSTRUCT* di) {
    RECT rc = di->rcItem;
    const bool field = di->itemState & ODS_COMBOBOXEDIT;
    const bool hot = (di->itemState & ODS_SELECTED) && !field;
    HBRUSH fill = CreateSolidBrush(hot ? RGB(62, 62, 62) : Theme::Field);
    FillRect(di->hDC, &rc, fill);
    DeleteObject(fill);
    if (hot) {
        RECT bar{rc.left + Px(2), rc.top + Px(5), rc.left + Px(5), rc.bottom - Px(5)};
        FillRound(di->hDC, bar, Px(1), Theme::Accent, Theme::Accent);
    }
    if (di->itemID == (UINT)-1) return;
    wchar_t text[256] = L"";
    SendMessageW(di->hwndItem, CB_GETLBTEXT, di->itemID, (LPARAM)text);
    SetBkMode(di->hDC, TRANSPARENT);
    SetTextColor(di->hDC, (di->itemState & ODS_DISABLED) ? Theme::Disabled : Theme::Text);
    HGDIOBJ old = SelectObject(di->hDC, U.font);
    rc.left += Px(field ? 4 : 10);
    DrawTextW(di->hDC, text, -1, &rc, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(di->hDC, old);
}

// Colors for labels, text boxes and dropdown lists (shared with the name prompt).
LRESULT CtlColor(UINT msg, HDC dc, HWND c) {
    wchar_t cls[32] = L"";
    GetClassNameW(c, cls, ARRAYSIZE(cls));
    const bool field = msg == WM_CTLCOLOREDIT || (msg == WM_CTLCOLORLISTBOX && c != U.sections) || !_wcsicmp(cls, L"Edit");
    SetTextColor(dc, c == U.hint ? Theme::Dim : Theme::Text);
    SetBkColor(dc, field ? Theme::Field : Theme::Bg);
    return (LRESULT)(field ? FieldBrush() : BgBrush());
}

// ---------------------------------------------------------------------------------------------
// Sections

const wchar_t* VersionLabel() {
    static const std::wstring label = L"Version " + AppVersion();
    return label.c_str();
}

std::vector<Row> GeneralRows() {
    return {
        {.kind = Kind::Slider, .label = L"Frame rate", .store = Store::General, .key = "fps", .def = "30", .min = 10, .max = 144, .unit = L" fps"},
        {.kind = Kind::Check, .label = L"Pause while a game or app is fullscreen", .store = Store::General, .key = "pause_on_fullscreen", .def = "1", .on = "1", .off = "0"},
        {.kind = Kind::Check, .label = L"Pause while windows cover the desktop", .store = Store::General, .key = "pause_when_covered", .def = "1", .on = "1", .off = "0"},
        {.kind = Kind::Check, .label = L"Pause on battery", .store = Store::General, .key = "pause_on_battery", .def = "1", .on = "1", .off = "0"},
        {.kind = Kind::Text, .label = L"Also pause while running", .store = Store::General, .key = "pause_apps", .def = "\"\""},
        {.kind = Kind::Check, .label = L"Start with Windows", .store = Store::Startup, .key = "startup"},
        {.kind = Kind::Check, .label = L"Start for all users of this PC (needs admin)", .store = Store::StartupAll, .key = "startup_all"},
        {.kind = Kind::Check, .label = L"Update automatically", .store = Store::AutoUpdate, .key = "auto_update"},
        {.kind = Kind::Button, .label = VersionLabel(), .store = Store::None, .key = "check_updates"},
    };
}

std::vector<Section> SectionsFor(Type type) {
    std::vector<Section> s;
    if (type == Type::Shader) {
        s.push_back({L"Shader", {
            {.kind = Kind::Slider, .label = L"Speed", .store = Store::Shader, .key = "speed", .def = "1", .min = 0, .max = 300, .scale = 0.01f, .unit = L"%"},
            {.kind = Kind::Slider, .label = L"Hue", .store = Store::Shader, .key = "hue", .def = "0", .min = 0, .max = 360, .unit = L"°"},
            {.kind = Kind::Slider, .label = L"Saturation", .store = Store::Shader, .key = "saturation", .def = "1", .min = 0, .max = 200, .scale = 0.01f, .unit = L"%"},
            {.kind = Kind::Slider, .label = L"Brightness", .store = Store::Shader, .key = "brightness", .def = "1", .min = 0, .max = 200, .scale = 0.01f, .unit = L"%"},
            {.kind = Kind::Slider, .label = L"Resolution", .store = Store::Default, .key = "scale", .def = "0.5", .min = 10, .max = 100, .scale = 0.01f, .unit = L"%"},
        }});
    } else if (type == Type::Particles) {
        s.push_back({L"Particles", {
            {.kind = Kind::Color, .label = L"Color", .store = Store::Particle, .key = "particles.color.value", .def = "\"#ffffff\"", .checkLabel = L"Random", .checkKey = "particles.color.value"},
            {.kind = Kind::Slider, .label = L"Amount", .store = Store::Particle, .key = "particles.number.value", .def = "80", .min = 1, .max = 600, .checkLabel = L"Fill screen", .checkKey = "particles.number.density.enable", .checkDef = "true"},
            {.kind = Kind::Combo, .label = L"Shape", .store = Store::Particle, .key = "particles.shape.type", .def = "\"circle\"",
             .choices = {{L"Circle", "circle"}, {L"Square", "edge"}, {L"Triangle", "triangle"}, {L"Polygon", "polygon"}, {L"Star", "star"}, {L"Image", "image"}}},
            {.kind = Kind::Slider, .label = L"Polygon / star sides", .store = Store::Particle, .key = "particles.shape.polygon.nb_sides", .def = "5", .min = 3, .max = 12},
            {.kind = Kind::Slider, .label = L"Size", .store = Store::Particle, .key = "particles.size.value", .def = "3", .min = 1, .max = 200, .unit = L" px", .checkLabel = L"Random", .checkKey = "particles.size.random"},
            {.kind = Kind::Slider, .label = L"Opacity", .store = Store::Particle, .key = "particles.opacity.value", .def = "0.5", .min = 0, .max = 100, .scale = 0.01f, .unit = L"%", .checkLabel = L"Random", .checkKey = "particles.opacity.random"},
            {.kind = Kind::Check, .label = L"Twinkle (animate opacity)", .store = Store::Particle, .key = "particles.opacity.anim.enable"},
            {.kind = Kind::Check, .label = L"Pulse (animate size)", .store = Store::Particle, .key = "particles.size.anim.enable"},
            {.kind = Kind::Slider, .label = L"Outline width", .store = Store::Particle, .key = "particles.shape.stroke.width", .def = "0", .min = 0, .max = 10, .unit = L" px"},
            {.kind = Kind::Color, .label = L"Outline color", .store = Store::Particle, .key = "particles.shape.stroke.color", .def = "\"#000000\""},
        }});
        s.push_back({L"Lines", {
            {.kind = Kind::Check, .label = L"Connect nearby particles with lines", .store = Store::Particle, .key = "particles.line_linked.enable"},
            {.kind = Kind::Color, .label = L"Color", .store = Store::Particle, .key = "particles.line_linked.color", .def = "\"#ffffff\""},
            {.kind = Kind::Slider, .label = L"Distance", .store = Store::Particle, .key = "particles.line_linked.distance", .def = "150", .min = 0, .max = 800, .unit = L" px"},
            {.kind = Kind::Slider, .label = L"Width", .store = Store::Particle, .key = "particles.line_linked.width", .def = "1", .min = 1, .max = 40, .scale = 0.5f, .unit = L" px"},
            {.kind = Kind::Slider, .label = L"Opacity", .store = Store::Particle, .key = "particles.line_linked.opacity", .def = "0.4", .min = 0, .max = 100, .scale = 0.01f, .unit = L"%"},
        }});
        s.push_back({L"Motion", {
            {.kind = Kind::Check, .label = L"Move", .store = Store::Particle, .key = "particles.move.enable", .def = "true"},
            {.kind = Kind::Slider, .label = L"Speed", .store = Store::Particle, .key = "particles.move.speed", .def = "6", .min = 0, .max = 120, .scale = 0.5f},
            {.kind = Kind::Combo, .label = L"Direction", .store = Store::Particle, .key = "particles.move.direction", .def = "\"none\"",
             .choices = {{L"Any", "none"}, {L"Up", "top"}, {L"Up right", "top-right"}, {L"Right", "right"}, {L"Down right", "bottom-right"},
                         {L"Down", "bottom"}, {L"Down left", "bottom-left"}, {L"Left", "left"}, {L"Up left", "top-left"}}},
            {.kind = Kind::Combo, .label = L"At the screen edge", .store = Store::Particle, .key = "particles.move.out_mode", .def = "\"out\"",
             .choices = {{L"Wrap around", "out"}, {L"Bounce", "bounce"}}},
            {.kind = Kind::Check, .label = L"Move in straight lines", .store = Store::Particle, .key = "particles.move.straight"},
            {.kind = Kind::Check, .label = L"Random speeds", .store = Store::Particle, .key = "particles.move.random"},
            {.kind = Kind::Check, .label = L"Bounce off each other", .store = Store::Particle, .key = "particles.move.bounce"},
            {.kind = Kind::Check, .label = L"Attract each other", .store = Store::Particle, .key = "particles.move.attract.enable"},
        }});
        s.push_back({L"Mouse", {
            {.kind = Kind::Combo, .label = L"On hover", .store = Store::Particle, .key = "interactivity.events.onhover.mode", .def = "\"grab\"",
             .choices = {{L"Grab (draw lines to cursor)", "grab"}, {L"Bubble (grow / fade)", "bubble"}, {L"Repulse (push away)", "repulse"}},
             .checkLabel = L"On", .checkKey = "interactivity.events.onhover.enable", .checkDef = "true"},
            {.kind = Kind::Combo, .label = L"On click", .store = Store::Particle, .key = "interactivity.events.onclick.mode", .def = "\"push\"",
             .choices = {{L"Push (add particles)", "push"}, {L"Remove particles", "remove"}, {L"Bubble", "bubble"}, {L"Repulse (blast away)", "repulse"}},
             .checkLabel = L"On", .checkKey = "interactivity.events.onclick.enable", .checkDef = "true"},
            {.kind = Kind::Check, .label = L"React even when the cursor is over windows", .store = Store::Particle, .key = "interactivity.detect_on", .def = "\"canvas\"", .on = "\"window\"", .off = "\"canvas\""},
            {.kind = Kind::Slider, .label = L"Grab distance", .store = Store::Particle, .key = "interactivity.modes.grab.distance", .def = "400", .min = 0, .max = 800, .unit = L" px"},
            {.kind = Kind::Slider, .label = L"Repulse distance", .store = Store::Particle, .key = "interactivity.modes.repulse.distance", .def = "200", .min = 0, .max = 800, .unit = L" px"},
            {.kind = Kind::Slider, .label = L"Bubble size", .store = Store::Particle, .key = "interactivity.modes.bubble.size", .def = "40", .min = 0, .max = 200, .unit = L" px"},
            {.kind = Kind::Slider, .label = L"Bubble distance", .store = Store::Particle, .key = "interactivity.modes.bubble.distance", .def = "400", .min = 0, .max = 800, .unit = L" px"},
            {.kind = Kind::Slider, .label = L"Particles per click", .store = Store::Particle, .key = "interactivity.modes.push.particles_nb", .def = "4", .min = 1, .max = 20},
        }});
        s.push_back({L"Background", {
            {.kind = Kind::Color, .label = L"Color", .store = Store::Particle, .key = "config_demo.background_color", .def = "\"#000000\""},
            {.kind = Kind::File, .label = L"Image", .store = Store::Particle, .key = "config_demo.background_image", .def = "\"\""},
            {.kind = Kind::Combo, .label = L"Image size", .store = Store::Particle, .key = "config_demo.background_size", .def = "\"cover\"",
             .choices = {{L"Fill screen", "cover"}, {L"Fit screen", "contain"}, {L"Original size", "auto"}, {L"20% wide", "20%"},
                         {L"40% wide", "40%"}, {L"60% wide", "60%"}, {L"80% wide", "80%"}}},
            {.kind = Kind::Combo, .label = L"Image position", .store = Store::Particle, .key = "config_demo.background_position", .def = "\"50% 50%\"",
             .choices = {{L"Center", "50% 50%"}, {L"Left", "0 50%"}, {L"Right", "100% 50%"}, {L"Top", "50% 0"}, {L"Bottom", "50% 100%"}}},
            {.kind = Kind::File, .label = L"Particle image", .store = Store::Particle, .key = "particles.shape.image.src", .def = "\"\""},
        }});
    } else {
        s.push_back({L"Picture", {
            {.kind = Kind::Combo, .label = L"Fit", .store = Store::Default, .key = "fit", .def = "\"cover\"",
             .choices = {{L"Fill screen (crop)", "cover"}, {L"Fit screen (bars)", "contain"}, {L"Stretch", "stretch"}}},
        }});
    }
    // RGB rainbow colors, for every kind of wallpaper (videos excepted: they go straight to the screen).
    s.push_back({L"Rainbow", {
        {.kind = Kind::Combo, .label = type == Type::Picture ? L"Rainbow colors (pictures and GIFs)" : L"Rainbow colors", .store = Store::Shader,
         .key = "rainbow", .def = "0", .choices = {{L"Off", "0"}, {L"Cycle: every color changes together", "1"}, {L"Wave: a rainbow sweeps across", "2"}}},
        {.kind = Kind::Slider, .label = L"Rainbow speed", .store = Store::Shader, .key = "rainbow_speed", .def = "1", .min = 10, .max = 300, .scale = 0.01f, .unit = L"%"},
    }});
    s.push_back({L"General", GeneralRows()});
    return s;
}

// ---------------------------------------------------------------------------------------------
// Values

const wchar_t* IniSection(Store st) {
    return st == Store::General ? L"general" : st == Store::Default ? L"default" : U.section.c_str();
}

Json ParseOr(const std::string& text) {
    Json v;
    std::string err;
    if (!Json::Parse(text, v, err)) v = Json::Of(text);
    return v;
}

Json GetValue(Store st, const char* key, const char* def) {
    if (st == Store::Startup) return Json::Of(StartupEnabled());
    if (st == Store::StartupAll) return Json::Of(AllUsersStartupEnabled());
    if (st == Store::AutoUpdate) return Json::Of(AutoUpdateEnabled());
    if (st == Store::None) return Json();
    if (st == Store::Particle) {
        const Json& j = Json::AtPath(U.particles, key);
        if (&j == &Json::Missing()) return ParseOr(def);
        return j.type == Json::Array && !j.arr.empty() ? j.arr[0] : j;
    }
    wchar_t buf[2048];
    GetPrivateProfileStringW(IniSection(st), Utf8ToWide(key).c_str(), L"\x01", buf, ARRAYSIZE(buf), ConfigPath().c_str());
    if (buf[0] == L'\x01') return ParseOr(def);
    return ParseOr(WideToUtf8(buf));
}

void SetValue(Store st, const char* key, const Json& v) {
    if (st == Store::Startup) {
        SetStartup(v.Flag(false));
        return;
    }
    if (st == Store::StartupAll) {
        SetAllUsersStartup(v.Flag(false), U.wnd);
        return;
    }
    if (st == Store::AutoUpdate) {
        SetAutoUpdate(v.Flag(true));
        return;
    }
    std::string text = st == Store::Particle || st == Store::Shader || v.type != Json::String ? v.Dump() : v.str;
    if ((st == Store::General || st == Store::Default) && v.type == Json::Bool) text = v.boolean ? "1" : "0";
    WritePrivateProfileStringW(IniSection(st), Utf8ToWide(key).c_str(), Utf8ToWide(text).c_str(), ConfigPath().c_str());
    if (st == Store::Particle) Json::SetPath(U.particles, key, v);
    RequestReload();
}

COLORREF ParseColor(const std::string& s) {
    std::string h = s;
    if (!h.empty() && h[0] == '#') h.erase(0, 1);
    if (h.size() == 3) h = {h[0], h[0], h[1], h[1], h[2], h[2]};
    if (h.size() != 6) return RGB(255, 255, 255);
    long v = strtol(h.c_str(), nullptr, 16);
    return RGB((v >> 16) & 255, (v >> 8) & 255, v & 255);
}

std::string ColorHex(COLORREF c) {
    char buf[8];
    snprintf(buf, sizeof(buf), "#%02x%02x%02x", GetRValue(c), GetGValue(c), GetBValue(c));
    return buf;
}

std::wstring FormatValue(const Row& r, int pos) {
    wchar_t buf[32];
    if (!wcscmp(r.unit, L"%") || r.scale == 1) swprintf_s(buf, L"%d%s", pos, r.unit);
    else swprintf_s(buf, L"%g%s", pos * r.scale, r.unit);
    return buf;
}

// ---------------------------------------------------------------------------------------------
// Building

HWND Make(const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, int id, DWORD ex = 0) {
    if (!wcscmp(cls, WC_COMBOBOXW)) style |= CBS_OWNERDRAWFIXED | CBS_HASSTRINGS;
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, U.wnd, (HMENU)(INT_PTR)id,
                             GetModuleHandleW(nullptr), nullptr);
    SendMessageW(c, WM_SETFONT, (WPARAM)U.font, TRUE);
    if (!wcscmp(cls, WC_COMBOBOXW)) {
        AllowDark(c);
        SetWindowTheme(c, L"DarkMode_CFD", nullptr);
        COMBOBOXINFO ci{sizeof(ci)};
        if (GetComboBoxInfo(c, &ci)) {
            AllowDark(ci.hwndList);
            SetWindowTheme(ci.hwndList, L"DarkMode_Explorer", nullptr);
        }
    } else if (!wcscmp(cls, WC_EDITW)) {
        AllowDark(c);
        SetWindowTheme(c, L"DarkMode_CFD", nullptr);
    } else if (!wcscmp(cls, WC_LISTBOXW)) {
        AllowDark(c);
        SetWindowTheme(c, L"DarkMode_Explorer", nullptr);
    }
    return c;
}

HWND MakeCheck(const wchar_t* text, int x, int y, int w, int h, int id) {
    HWND c = Make(L"BUTTON", text, BS_OWNERDRAW | WS_TABSTOP, x, y, w, h, id);
    SetWindowLongPtrW(c, GWLP_USERDATA, kCheckbox);
    return c;
}

HWND MakeButton(const wchar_t* text, int x, int y, int w, int h, int id, bool primary = false) {
    HWND c = Make(L"BUTTON", text, BS_OWNERDRAW | WS_TABSTOP, x, y, w, h, id);
    SetWindowLongPtrW(c, GWLP_USERDATA, primary ? kPrimary : kButton);
    return c;
}

Type TypeOf(const std::wstring& path) {
    std::wstring ext = ToLower(path.substr(path.find_last_of(L'.') == std::wstring::npos ? path.size() : path.find_last_of(L'.')));
    if (ext == L".hlsl" || ext == L".fx" || ext == L".shader") return Type::Shader;
    if (ext == L".json") return Type::Particles;
    return Type::Picture;
}

void ClearPage() {
    for (HWND h : U.page) DestroyWindow(h);
    U.page.clear();
}

void ShowSection(int index) {
    ClearPage();
    if (index < 0 || index >= (int)U.secs.size()) return;
    U.current = index;
    SetWindowTextW(U.title, U.secs[index].name);

    const int x0 = Px(kSideW + 36), right = Px(kClientW - 20);
    const int ctlX = x0 + Px(kLabelW), ctlH = Px(26);
    int y = Px(kTopH + 44);
    auto& rows = U.secs[index].rows;
    for (size_t i = 0; i < rows.size(); ++i) {
        Row& r = rows[i];
        const int id = IDC_ROW + (int)i * 8;
        const int cy = y + (Px(kRowH) - ctlH) / 2;
        Json v = GetValue(r.store, r.key, r.def);
        r.ctl = r.value = r.check = r.browse = r.clear = nullptr;

        if (r.kind != Kind::Check)
            U.page.push_back(Make(L"STATIC", r.label, SS_CENTERIMAGE | SS_NOPREFIX, x0, y, Px(kLabelW) - Px(8), Px(kRowH), -1));

        int after = ctlX;  // where a trailing checkbox goes
        switch (r.kind) {
        case Kind::Slider: {
            int w = r.checkLabel ? Px(150) : Px(250);
            r.ctl = Make(TRACKBAR_CLASSW, L"", TBS_HORZ | TBS_NOTICKS | WS_TABSTOP, ctlX, cy, w, ctlH, id);
            SendMessageW(r.ctl, TBM_SETRANGEMIN, FALSE, r.min);
            SendMessageW(r.ctl, TBM_SETRANGEMAX, FALSE, r.max);
            SendMessageW(r.ctl, TBM_SETPAGESIZE, 0, std::max(1, (r.max - r.min) / 20));
            int pos = (int)std::lround(v.Num(0) / r.scale);
            SendMessageW(r.ctl, TBM_SETPOS, TRUE, std::clamp(pos, r.min, r.max));
            r.value = Make(L"STATIC", FormatValue(r, pos).c_str(), SS_CENTERIMAGE, ctlX + w + Px(6), y, Px(56), Px(kRowH), -1);
            U.page.push_back(r.value);
            after = ctlX + w + Px(64);
            break;
        }
        case Kind::Check:
            r.ctl = MakeCheck(r.label, x0, cy, right - x0, ctlH, id);
            SetChecked(r.ctl, v.Dump() == ParseOr(r.on).Dump());
            break;
        case Kind::Color: {
            bool random = v.Str("") == "random";
            r.color = random ? RGB(255, 255, 255) : ParseColor(v.Str("#ffffff"));
            r.ctl = Make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, ctlX, cy, Px(72), ctlH, id);
            after = ctlX + Px(88);
            break;
        }
        case Kind::Combo: {
            r.ctl = Make(WC_COMBOBOXW, L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, ctlX, cy, Px(220), Px(300), id);
            std::string cur = v.type == Json::String ? v.str : v.Dump();
            int sel = -1;
            for (size_t c = 0; c < r.choices.size(); ++c) {
                SendMessageW(r.ctl, CB_ADDSTRING, 0, (LPARAM)r.choices[c].label);
                if (cur == r.choices[c].value) sel = (int)c;
            }
            if (sel < 0) {  // a value set by hand in the file: keep showing it
                SendMessageW(r.ctl, CB_ADDSTRING, 0, (LPARAM)Utf8ToWide(cur).c_str());
                sel = (int)r.choices.size();
            }
            SendMessageW(r.ctl, CB_SETCURSEL, sel, 0);
            after = ctlX + Px(232);
            break;
        }
        case Kind::Text:
            r.ctl = Make(WC_EDITW, Utf8ToWide(v.Str("")).c_str(), ES_AUTOHSCROLL | WS_TABSTOP, ctlX, cy, right - ctlX, ctlH, id, WS_EX_CLIENTEDGE);
            SendMessageW(r.ctl, EM_SETCUEBANNER, TRUE, (LPARAM)L"e.g. cs2.exe, valorant.exe");
            break;
        case Kind::File: {
            int w = right - ctlX - Px(156);
            r.ctl = Make(WC_EDITW, Utf8ToWide(v.Str("")).c_str(), ES_AUTOHSCROLL | ES_READONLY, ctlX, cy, w, ctlH, id, WS_EX_CLIENTEDGE);
            SendMessageW(r.ctl, EM_SETCUEBANNER, TRUE, (LPARAM)L"None");
            r.browse = MakeButton(L"Browse...", ctlX + w + Px(6), cy, Px(80), ctlH, id + 2);
            r.clear = MakeButton(L"Clear", ctlX + w + Px(90), cy, Px(64), ctlH, id + 3);
            U.page.push_back(r.browse);
            U.page.push_back(r.clear);
            break;
        }
        case Kind::Button:  // "Check for updates" (same as the tray menu item); off in dev builds
            r.ctl = MakeButton(UpdatesSupported() ? UpdateMenuText().c_str() : L"Updates are off in dev builds", ctlX, cy, Px(220), ctlH, id);
            EnableWindow(r.ctl, UpdatesSupported() && !UpdateBusy());
            break;
        }
        U.page.push_back(r.ctl);

        if (r.checkLabel) {
            r.check = MakeCheck(r.checkLabel, after, cy, right - after, ctlH, id + 1);
            bool checked = r.kind == Kind::Color && !strcmp(r.checkKey, r.key)
                               ? v.Str("") == "random"
                               : GetValue(r.store, r.checkKey, r.checkDef).Flag(false);
            SetChecked(r.check, checked);
            U.page.push_back(r.check);
        }
        y += Px(kRowH);
    }

    bool resettable = U.type != Type::Picture && wcscmp(U.secs[index].name, L"General") != 0;
    EnableWindow(U.reset, resettable);
    EnableWindow(U.openFile, U.type != Type::Picture);
}

}  // namespace

// The "Check for updates" button follows the updater (checking, ready to install, ...).
void RefreshUpdateButton() {
    if (!U.wnd || U.current >= (int)U.secs.size()) return;
    for (auto& r : U.secs[U.current].rows)
        if (r.kind == Kind::Button && r.ctl && UpdatesSupported()) {
            SetWindowTextW(r.ctl, UpdateMenuText().c_str());
            EnableWindow(r.ctl, !UpdateBusy());
        }
}

namespace {

std::wstring IniSource() {
    wchar_t buf[MAX_PATH * 2];
    GetPrivateProfileStringW(L"default", L"source", L"", buf, ARRAYSIZE(buf), ConfigPath().c_str());
    return buf[0] ? ResolvePath(buf) : CurrentSource();
}

// (Re)reads the current wallpaper and rebuilds the section list.
void LoadWallpaper(bool keepSection) {
    U.source = IniSource();
    U.type = TypeOf(U.source);
    U.section = OverrideSection(U.source);
    U.particles = Json();
    if (U.type == Type::Particles) {
        std::wstring err;
        if (!LoadParticleJson(U.source, U.particles, err)) U.type = Type::Picture;
    }
    std::wstring prev = U.secs.empty() ? L"" : U.secs[U.current].name;
    U.secs = SectionsFor(U.type);

    // Wallpaper picker: bundled ones, plus the current file if it lives elsewhere.
    U.entries = ListWallpapers();
    std::wstring cur = ToLower(U.source);
    int sel = -1;
    for (size_t i = 0; i < U.entries.size(); ++i)
        if (ToLower(ResolvePath(U.entries[i].rel)) == cur) sel = (int)i;
    if (sel < 0) {
        U.entries.push_back({U.source, L"File: " + FileName(U.source)});
        sel = (int)U.entries.size() - 1;
    }
    SendMessageW(U.wallpaper, CB_RESETCONTENT, 0, 0);
    for (auto& e : U.entries) SendMessageW(U.wallpaper, CB_ADDSTRING, 0, (LPARAM)e.label.c_str());
    SendMessageW(U.wallpaper, CB_SETCURSEL, sel, 0);

    U.profiles = ListProfiles();
    U.profiles.insert(U.profiles.begin(), L"");
    std::wstring active = ToLower(ActiveProfile());
    SendMessageW(U.profile, CB_RESETCONTENT, 0, 0);
    for (size_t i = 0; i < U.profiles.size(); ++i) {
        SendMessageW(U.profile, CB_ADDSTRING, 0, (LPARAM)(U.profiles[i].empty() ? L"Default" : U.profiles[i].c_str()));
        if (ToLower(U.profiles[i]) == active) SendMessageW(U.profile, CB_SETCURSEL, i, 0);
    }
    EnableWindow(U.delProfile, !active.empty());

    SendMessageW(U.sections, LB_RESETCONTENT, 0, 0);
    int show = 0;
    for (size_t i = 0; i < U.secs.size(); ++i) {
        SendMessageW(U.sections, LB_ADDSTRING, 0, (LPARAM)U.secs[i].name);
        if (keepSection && prev == U.secs[i].name) show = (int)i;
    }
    SendMessageW(U.sections, LB_SETCURSEL, show, 0);
    ShowSection(show);
}

void CreateFonts() {
    if (U.font) DeleteObject(U.font);
    if (U.bold) DeleteObject(U.bold);
    NONCLIENTMETRICSW ncm{sizeof(ncm)};
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0, U.dpi);
    U.font = CreateFontIndirectW(&ncm.lfMessageFont);
    LOGFONTW big = ncm.lfMessageFont;
    big.lfWeight = FW_SEMIBOLD;
    big.lfHeight = big.lfHeight * 13 / 10;
    U.bold = CreateFontIndirectW(&big);
}

void Layout() {
    ClearPage();
    for (HWND c = GetWindow(U.wnd, GW_CHILD); c;) {
        HWND next = GetWindow(c, GW_HWNDNEXT);
        DestroyWindow(c);
        c = next;
    }
    CreateFonts();
    const int W = Px(kClientW), H = Px(kClientH);
    Make(L"STATIC", L"Profile", SS_CENTERIMAGE, Px(20), Px(14), Px(80), Px(28), -1);
    U.profile = Make(WC_COMBOBOXW, L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, Px(100), Px(16), W - Px(330), Px(300), IDC_PROFILE);
    U.saveProfile = MakeButton(L"Save as new...", W - Px(220), Px(15), Px(110), Px(28), IDC_SAVEPROFILE);
    U.delProfile = MakeButton(L"Delete", W - Px(102), Px(15), Px(82), Px(28), IDC_DELPROFILE);
    Make(L"STATIC", L"Wallpaper", SS_CENTERIMAGE, Px(20), Px(56), Px(80), Px(28), -1);
    U.wallpaper = Make(WC_COMBOBOXW, L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, Px(100), Px(58), W - Px(220), Px(400), IDC_WALLPAPER);
    U.browse = MakeButton(L"Browse...", W - Px(110), Px(57), Px(90), Px(28), IDC_BROWSE);
    U.sections = Make(WC_LISTBOXW, L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_TABSTOP,
                      Px(20), Px(kTopH + 8), Px(kSideW), H - Px(kTopH + 8) - Px(kBottomH) - Px(8), IDC_SECTIONS);
    U.title = Make(L"STATIC", L"", SS_CENTERIMAGE, Px(kSideW + 36), Px(kTopH + 4), W - Px(kSideW + 56), Px(36), -1);
    SendMessageW(U.title, WM_SETFONT, (WPARAM)U.bold, TRUE);
    U.reset = MakeButton(L"Reset to defaults", Px(20), H - Px(44), Px(150), Px(30), IDC_RESET);
    U.openFile = MakeButton(L"Edit file", Px(178), H - Px(44), Px(100), Px(30), IDC_OPENFILE);
    U.hint = Make(L"STATIC", L"Changes save automatically", SS_CENTERIMAGE | SS_RIGHT, Px(290), H - Px(44), W - Px(410), Px(30), -1);
    U.close = MakeButton(L"Close", W - Px(110), H - Px(44), Px(90), Px(30), IDCANCEL, true);
    LoadWallpaper(true);
}

// ---------------------------------------------------------------------------------------------
// Name prompt (modal, owned by the settings window)

struct PromptState {
    HWND wnd = nullptr, edit = nullptr;
    bool done = false, ok = false;
    std::wstring text;
} P;

LRESULT CALLBACK PromptProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLOREDIT) return CtlColor(msg, (HDC)w, (HWND)l);
    if (msg == WM_DRAWITEM) {
        DrawButton((const DRAWITEMSTRUCT*)l);
        return TRUE;
    }
    if (msg == WM_COMMAND && (LOWORD(w) == IDOK || LOWORD(w) == IDCANCEL)) {
        if (LOWORD(w) == IDOK) {
            wchar_t buf[128];
            GetWindowTextW(P.edit, buf, ARRAYSIZE(buf));
            P.text = buf;
            P.ok = true;
        }
        P.done = true;
        return 0;
    }
    if (msg == WM_CLOSE) {
        P.done = true;
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

bool Prompt(const wchar_t* title, const wchar_t* label, std::wstring& out) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc{sizeof(wc)};
        wc.lpfnWndProc = PromptProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"LiteWallpaper.Prompt";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = BgBrush();
        RegisterClassExW(&wc);
        registered = true;
    }
    P = PromptState{};
    const DWORD style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
    RECT r{0, 0, Px(380), Px(130)};
    AdjustWindowRectExForDpi(&r, style, FALSE, WS_EX_DLGMODALFRAME, U.dpi);
    RECT owner;
    GetWindowRect(U.wnd, &owner);
    int w = r.right - r.left, h = r.bottom - r.top;
    P.wnd = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, L"LiteWallpaper.Prompt", title, style,
                            (owner.left + owner.right - w) / 2, (owner.top + owner.bottom - h) / 2, w, h, U.wnd, nullptr,
                            GetModuleHandleW(nullptr), nullptr);
    DarkTitleBar(P.wnd);
    auto child = [&](const wchar_t* cls, const wchar_t* text, DWORD st, int x, int y, int cw, int ch, int id, DWORD ex = 0) {
        HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | st, Px(x), Px(y), Px(cw), Px(ch), P.wnd,
                                 (HMENU)(INT_PTR)id, GetModuleHandleW(nullptr), nullptr);
        SendMessageW(c, WM_SETFONT, (WPARAM)U.font, TRUE);
        return c;
    };
    child(L"STATIC", label, 0, 16, 14, 348, 20, -1);
    P.edit = child(WC_EDITW, L"", ES_AUTOHSCROLL | WS_TABSTOP, 16, 38, 348, 26, 100, WS_EX_CLIENTEDGE);
    AllowDark(P.edit);
    SetWindowTheme(P.edit, L"DarkMode_CFD", nullptr);
    SetWindowLongPtrW(child(L"BUTTON", L"Save", BS_OWNERDRAW | WS_TABSTOP, 182, 84, 88, 30, IDOK), GWLP_USERDATA, kPrimary);
    SetWindowLongPtrW(child(L"BUTTON", L"Cancel", BS_OWNERDRAW | WS_TABSTOP, 276, 84, 88, 30, IDCANCEL), GWLP_USERDATA, kButton);
    EnableWindow(U.wnd, FALSE);
    ShowWindow(P.wnd, SW_SHOW);
    SetFocus(P.edit);

    MSG msg;
    while (!P.done && GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(P.wnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    if (msg.message == WM_QUIT) PostQuitMessage((int)msg.wParam);
    EnableWindow(U.wnd, TRUE);
    DestroyWindow(P.wnd);
    SetForegroundWindow(U.wnd);
    out = P.text;
    return P.ok;
}

// ---------------------------------------------------------------------------------------------
// Events

bool PickFile(const wchar_t* filter, std::wstring& out) {
    wchar_t file[MAX_PATH * 2] = L"";
    OPENFILENAMEW ofn{sizeof(ofn)};
    ofn.hwndOwner = U.wnd;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = file;
    ofn.nMaxFile = ARRAYSIZE(file);
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) return false;
    out = file;
    return true;
}

void OnRowCommand(int id, int code) {
    auto& rows = U.secs[U.current].rows;
    size_t i = (size_t)(id - IDC_ROW) / 8;
    int part = (id - IDC_ROW) % 8;
    if (i >= rows.size()) return;
    Row& r = rows[i];

    if (part == 1 && code == BN_CLICKED) {  // trailing checkbox
        bool checked = Checked(r.check);
        if (r.kind == Kind::Color && !strcmp(r.checkKey, r.key))
            SetValue(r.store, r.key, Json::Of(checked ? std::string("random") : ColorHex(r.color)));
        else
            SetValue(r.store, r.checkKey, Json::Of(checked));
        return;
    }
    if (part == 2 || part == 3) {  // file browse / clear
        std::wstring path;
        if (part == 2 && !PickFile(L"Images (*.png;*.jpg;*.jpeg;*.gif;*.bmp)\0*.png;*.jpg;*.jpeg;*.gif;*.bmp\0All files\0*.*\0", path)) return;
        SetWindowTextW(r.ctl, path.c_str());
        SetValue(r.store, r.key, Json::Of(WideToUtf8(path)));
        return;
    }
    switch (r.kind) {
    case Kind::Check:
        if (code != BN_CLICKED) break;
        SetValue(r.store, r.key, ParseOr(Checked(r.ctl) ? r.on : r.off));
        // Startup can be refused (admin prompt cancelled) and the two rows affect each other:
        // show what's actually set now.
        if (r.store == Store::Startup || r.store == Store::StartupAll)
            for (auto& o : rows)
                if (o.store == Store::Startup || o.store == Store::StartupAll)
                    SetChecked(o.ctl, GetValue(o.store, o.key, o.def).Flag(false));
        break;
    case Kind::Color:
        if (code == BN_CLICKED) {
            CHOOSECOLORW cc{sizeof(cc)};
            cc.hwndOwner = U.wnd;
            cc.rgbResult = r.color;
            cc.lpCustColors = U.custom;
            cc.Flags = CC_FULLOPEN | CC_RGBINIT;
            if (!ChooseColorW(&cc)) break;
            r.color = cc.rgbResult;
            InvalidateRect(r.ctl, nullptr, TRUE);
            if (r.check && !strcmp(r.checkKey, r.key)) SetChecked(r.check, false);
            SetValue(r.store, r.key, Json::Of(ColorHex(r.color)));
        }
        break;
    case Kind::Combo:
        if (code == CBN_SELCHANGE) {
            int sel = (int)SendMessageW(r.ctl, CB_GETCURSEL, 0, 0);
            if (sel >= 0 && sel < (int)r.choices.size()) SetValue(r.store, r.key, Json::Of(std::string(r.choices[sel].value)));
        }
        break;
    case Kind::Button:
        if (code == BN_CLICKED) {
            UpdateMenuCommand(U.wnd);
            SetWindowTextW(r.ctl, UpdateMenuText().c_str());
            EnableWindow(r.ctl, !UpdateBusy());
        }
        break;
    case Kind::Text:
        if (code == EN_CHANGE) {
            wchar_t buf[1024];
            GetWindowTextW(r.ctl, buf, ARRAYSIZE(buf));
            SetValue(r.store, r.key, Json::Of(WideToUtf8(buf)));
        }
        break;
    default: break;
    }
}

void OnSlider(HWND bar) {
    for (auto& r : U.secs[U.current].rows) {
        if (r.ctl != bar || r.kind != Kind::Slider) continue;
        int pos = (int)SendMessageW(bar, TBM_GETPOS, 0, 0);
        SetWindowTextW(r.value, FormatValue(r, pos).c_str());
        SetValue(r.store, r.key, Json::Of((double)(pos * r.scale)));
        return;
    }
}

// Sidebar entries: vertically centered text, a soft highlight and an accent bar for the
// selected one.
void DrawSectionItem(const DRAWITEMSTRUCT* di) {
    if (di->itemID == (UINT)-1) return;
    RECT rc = di->rcItem;
    bool selected = di->itemState & ODS_SELECTED;
    FillRect(di->hDC, &rc, BgBrush());
    if (selected) {
        RECT pill{rc.left, rc.top + Px(2), rc.right, rc.bottom - Px(2)};
        FillRound(di->hDC, pill, Px(4), Theme::Selected, Theme::Selected);
        RECT bar{rc.left, rc.top + Px(9), rc.left + Px(3), rc.bottom - Px(9)};
        FillRound(di->hDC, bar, Px(1), Theme::Accent, Theme::Accent);
    }
    wchar_t text[64] = L"";
    SendMessageW(di->hwndItem, LB_GETTEXT, di->itemID, (LPARAM)text);
    SetBkMode(di->hDC, TRANSPARENT);
    SetTextColor(di->hDC, Theme::Text);
    HGDIOBJ old = SelectObject(di->hDC, U.font);
    RECT t = rc;
    t.left += Px(14);
    DrawTextW(di->hDC, text, -1, &t, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
    SelectObject(di->hDC, old);
}

void DrawColorButton(const DRAWITEMSTRUCT* di) {
    for (auto& r : U.secs[U.current].rows) {
        if (r.ctl != di->hwndItem) continue;
        RECT rc = di->rcItem;
        FillRect(di->hDC, &rc, BgBrush());
        FillRound(di->hDC, rc, Px(4), Theme::Field, (di->itemState & ODS_FOCUS) ? Theme::Accent : Theme::Border);
        InflateRect(&rc, -Px(3), -Px(3));
        bool random = r.check && !strcmp(r.checkKey, r.key) && Checked(r.check);
        if (random) {  // rainbow swatch for "random"
            int w = rc.right - rc.left;
            for (int x = 0; x < w; ++x) {
                float h = (float)x / w * 6;
                int k = (int)h;
                float f = h - k;
                int q = (int)(255 * (1 - f)), t = (int)(255 * f);
                COLORREF c = k == 0 ? RGB(255, t, 0) : k == 1 ? RGB(q, 255, 0) : k == 2 ? RGB(0, 255, t) : k == 3 ? RGB(0, q, 255) : k == 4 ? RGB(t, 0, 255) : RGB(255, 0, q);
                RECT line{rc.left + x, rc.top, rc.left + x + 1, rc.bottom};
                HBRUSH b = CreateSolidBrush(c);
                FillRect(di->hDC, &line, b);
                DeleteObject(b);
            }
        } else {
            HBRUSH fill = CreateSolidBrush(r.color);
            FillRect(di->hDC, &rc, fill);
            DeleteObject(fill);
        }
        return;
    }
}

LRESULT CALLBACK SettingsProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_CREATE:
        U.wnd = h;
        U.dpi = GetDpiForWindow(h);
        DarkTitleBar(h);
        Layout();
        return 0;

    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX:
        return CtlColor(msg, (HDC)w, (HWND)l);

    case WM_NOTIFY: {
        auto* nm = (NMHDR*)l;
        wchar_t cls[32] = L"";
        if (nm->code == NM_CUSTOMDRAW && GetClassNameW(nm->hwndFrom, cls, ARRAYSIZE(cls)) && !wcscmp(cls, TRACKBAR_CLASSW))
            return DrawTrackbar((NMCUSTOMDRAW*)l);
        break;
    }

    case WM_HSCROLL:
        if (l) OnSlider((HWND)l);
        return 0;

    case WM_MEASUREITEM: {
        auto* mi = (MEASUREITEMSTRUCT*)l;
        mi->itemHeight = mi->CtlType == ODT_COMBOBOX ? (mi->itemID == (UINT)-1 ? Px(20) : Px(26)) : Px(34);
        return TRUE;
    }

    case WM_DRAWITEM: {
        auto* di = (const DRAWITEMSTRUCT*)l;
        if (di->CtlType == ODT_LISTBOX) DrawSectionItem(di);
        else if (di->CtlType == ODT_COMBOBOX) DrawComboItem(di);
        else if (ButtonKind(di->hwndItem)) DrawButton(di);
        else DrawColorButton(di);
        return TRUE;
    }

    case WM_COMMAND: {
        int id = LOWORD(w), code = HIWORD(w);
        if (code == BN_DOUBLECLICKED && l && ButtonKind((HWND)l)) code = BN_CLICKED;
        if (code == BN_CLICKED && l && ButtonKind((HWND)l) == kCheckbox) SetChecked((HWND)l, !Checked((HWND)l));
        if (id == IDCANCEL) {
            DestroyWindow(h);
        } else if (id == IDC_PROFILE && code == CBN_SELCHANGE) {
            int sel = (int)SendMessageW(U.profile, CB_GETCURSEL, 0, 0);
            if (sel >= 0 && sel < (int)U.profiles.size()) {
                SetActiveProfile(U.profiles[sel]);
                RequestReload();
                LoadWallpaper(true);
            }
        } else if (id == IDC_SAVEPROFILE) {
            std::wstring name, err;
            if (Prompt(L"Save profile", L"Name for the new profile (it starts as a copy of the current one):", name)) {
                if (SaveProfileAs(name, err)) {
                    RequestReload();
                    LoadWallpaper(true);
                } else {
                    MessageBoxW(h, err.c_str(), L"Save profile", MB_OK | MB_ICONWARNING);
                }
            }
        } else if (id == IDC_DELPROFILE) {
            std::wstring name = ActiveProfile();
            std::wstring q = L"Delete the profile \"" + name + L"\"? The Default profile will be used instead.";
            if (!name.empty() && MessageBoxW(h, q.c_str(), L"Delete profile", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES) {
                DeleteProfile(name);
                RequestReload();
                LoadWallpaper(true);
            }
        } else if (id == IDC_SECTIONS && code == LBN_SELCHANGE) {
            ShowSection((int)SendMessageW(U.sections, LB_GETCURSEL, 0, 0));
        } else if (id == IDC_WALLPAPER && code == CBN_SELCHANGE) {
            int sel = (int)SendMessageW(U.wallpaper, CB_GETCURSEL, 0, 0);
            if (sel >= 0 && sel < (int)U.entries.size()) {
                WritePrivateProfileStringW(L"default", L"source", U.entries[sel].rel.c_str(), ConfigPath().c_str());
                RequestReload();
                LoadWallpaper(false);
            }
        } else if (id == IDC_BROWSE) {
            std::wstring path;
            if (PickFile(L"Wallpapers\0*.hlsl;*.json;*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.wmv;*.gif;*.png;*.jpg;*.jpeg;*.bmp\0"
                         L"All files\0*.*\0", path)) {
                WritePrivateProfileStringW(L"default", L"source", path.c_str(), ConfigPath().c_str());
                RequestReload();
                LoadWallpaper(false);
            }
        } else if (id == IDC_RESET) {
            WritePrivateProfileStringW(U.section.c_str(), nullptr, nullptr, ConfigPath().c_str());
            if (U.type == Type::Shader) WritePrivateProfileStringW(L"default", L"scale", L"0.5", ConfigPath().c_str());
            RequestReload();
            LoadWallpaper(true);
        } else if (id == IDC_OPENFILE) {
            ShellExecuteW(nullptr, L"open", L"notepad.exe", (L"\"" + U.source + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
        } else if (id >= IDC_ROW) {
            OnRowCommand(id, code);
        }
        return 0;
    }

    case WM_DPICHANGED: {
        U.dpi = HIWORD(w);
        auto* r = (RECT*)l;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        Layout();
        return 0;
    }

    case WM_DESTROY:
        ClearPage();
        if (U.font) DeleteObject(U.font);
        if (U.bold) DeleteObject(U.bold);
        U = Ui{};
        // Give back everything the window used.
        SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

}  // namespace

HWND SettingsWindow() { return U.wnd; }

void ShowSettings() {
    if (U.wnd) {
        ShowWindow(U.wnd, SW_RESTORE);
        SetForegroundWindow(U.wnd);
        return;
    }
    static bool registered = false;
    if (!registered) {
        INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_BAR_CLASSES | ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES};
        InitCommonControlsEx(&icc);
        WNDCLASSEXW wc{sizeof(wc)};
        wc.lpfnWndProc = SettingsProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = kClass;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = BgBrush();
        wc.hIcon = AppIcon(true);
        wc.hIconSm = AppIcon();
        RegisterClassExW(&wc);
        registered = true;
    }

    // Size the window for the DPI of the monitor the cursor is on, centered on its work area.
    POINT pt;
    GetCursorPos(&pt);
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi{sizeof(mi)};
    GetMonitorInfoW(mon, &mi);
    UINT dpi = 96;
    HWND probe = CreateWindowExW(0, L"STATIC", L"", WS_POPUP, mi.rcWork.left, mi.rcWork.top, 1, 1, nullptr, nullptr, nullptr, nullptr);
    if (probe) {
        dpi = GetDpiForWindow(probe);
        DestroyWindow(probe);
    }
    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r{0, 0, MulDiv(kClientW, dpi, 96), MulDiv(kClientH, dpi, 96)};
    AdjustWindowRectExForDpi(&r, style, FALSE, WS_EX_CONTROLPARENT, dpi);
    int w = r.right - r.left, h = r.bottom - r.top;
    int x = (mi.rcWork.left + mi.rcWork.right - w) / 2, y = (mi.rcWork.top + mi.rcWork.bottom - h) / 2;
    HWND wnd = CreateWindowExW(WS_EX_CONTROLPARENT, kClass, L"LiteWallpaper Settings", style, x, y, w, h, nullptr, nullptr,
                               GetModuleHandleW(nullptr), nullptr);
    if (!wnd) {
        Log(L"Settings window failed: %u", GetLastError());
        return;
    }
    ShowWindow(wnd, SW_SHOWNORMAL);
    SetForegroundWindow(wnd);
}
