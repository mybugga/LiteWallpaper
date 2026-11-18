#include "app.h"

// Live wallpapers live in a window Explorer creates between the desktop icons and the static
// wallpaper. Sending the undocumented 0x052C message to Progman makes Explorer create it.
//
// Before Windows 11 24H2 that window is a top-level "WorkerW" right after the window holding
// SHELLDLL_DefView (the icons). From 24H2 on, the icons and the WorkerW are both children of
// Progman, and the wallpaper window has to sit between them.

static BOOL CALLBACK FindIconHostProc(HWND top, LPARAM lp) {
    if (FindWindowExW(top, nullptr, L"SHELLDLL_DefView", nullptr)) {
        *(HWND*)lp = FindWindowExW(nullptr, top, L"WorkerW", nullptr);
        return FALSE;
    }
    return TRUE;
}

DesktopHost FindDesktopHost() {
    DesktopHost host;
    for (int attempt = 0; attempt < 20; ++attempt) {
        HWND progman = FindWindowW(L"Progman", nullptr);
        if (!progman) {
            Sleep(100);
            continue;
        }
        DWORD_PTR result = 0;
        SendMessageTimeoutW(progman, 0x052C, 0xD, 0x1, SMTO_NORMAL, 1000, &result);

        HWND defView = FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr);
        HWND worker = FindWindowExW(progman, nullptr, L"WorkerW", nullptr);
        if (defView && worker) {  // 24H2+
            host.parent = progman;
            host.insertAfter = defView;
            return host;
        }

        HWND legacyWorker = nullptr;
        EnumWindows(FindIconHostProc, (LPARAM)&legacyWorker);
        if (legacyWorker) {
            host.parent = legacyWorker;
            return host;
        }
        Sleep(100);
    }
    Log(L"Desktop wallpaper layer not found");
    return host;
}

static void DumpWindow(HWND h, int depth) {
    wchar_t cls[128] = L"";
    GetClassNameW(h, cls, ARRAYSIZE(cls));
    RECT r{};
    GetWindowRect(h, &r);
    Log(L"%*s%p %s [%d,%d %dx%d] style=%08X ex=%08X visible=%d", depth * 2, L"", h, cls, r.left, r.top,
        r.right - r.left, r.bottom - r.top, (UINT)GetWindowLongW(h, GWL_STYLE), (UINT)GetWindowLongW(h, GWL_EXSTYLE),
        IsWindowVisible(h));
    if (depth < 2)
        for (HWND c = FindWindowExW(h, nullptr, nullptr, nullptr); c; c = FindWindowExW(h, c, nullptr, nullptr))
            DumpWindow(c, depth + 1);
}

void DumpDesktopTree() {
    Log(L"--- desktop window tree ---");
    if (HWND progman = FindWindowW(L"Progman", nullptr)) DumpWindow(progman, 0);
    for (HWND w = FindWindowExW(nullptr, nullptr, L"WorkerW", nullptr); w; w = FindWindowExW(nullptr, w, L"WorkerW", nullptr))
        DumpWindow(w, 0);
}

void RefreshDesktop(const DesktopHost& host) {
    if (host.parent && IsWindow(host.parent))
        RedrawWindow(host.parent, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
}
