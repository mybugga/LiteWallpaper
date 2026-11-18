// Updates from GitHub releases. A background thread asks GitHub for the latest release, downloads
// its zip into the user's settings folder, checks the SHA-256 GitHub publishes for it, and unpacks
// it with Windows' own tar.exe. The main thread then swaps the files in (renaming the running exe
// out of the way, which Windows allows) and restarts the app, but only while no game or fullscreen
// app is running and the settings window is closed. Local "dev" builds never update themselves.
#include "app.h"
#include "json.h"
#include "version.h"
#include <bcrypt.h>
#include <shellapi.h>
#include <winhttp.h>
#include <atomic>
#include <mutex>

namespace {

struct Release {
    std::wstring version;  // "1.2.3"
    std::wstring zipUrl;
    std::string sha256;    // lower-case hex; empty when GitHub didn't publish one
};

struct {
    std::mutex lock;
    std::atomic<bool> busy{false};
    bool download = false;   // the running check also downloads what it finds
    bool userAsked = false;  // started from the tray menu: report the outcome
    bool found = false;      // the last check found a newer release
    Release latest;
    std::wstring staged;     // unpacked release waiting to be installed
    std::wstring error;
    bool needsAdmin = false;   // the app folder isn't writable; installing needs a click and UAC
} Upd;

const wchar_t kExeName[] = L"LiteWallpaper.exe";

std::wstring OwnExePath() {
    wchar_t exe[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
    return std::wstring(exe, n);
}

bool Exists(const std::wstring& path) { return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES; }

// "1.2.3" > "1.2" > "1.1.9". Anything after the numbers ("-beta") is ignored.
int CompareVersions(const std::wstring& a, const std::wstring& b) {
    const wchar_t *pa = a.c_str(), *pb = b.c_str();
    for (int i = 0; i < 4; ++i) {
        long x = wcstol(pa, (wchar_t**)&pa, 10), y = wcstol(pb, (wchar_t**)&pb, 10);
        if (x != y) return x < y ? -1 : 1;
        if (*pa == L'.') ++pa;
        if (*pb == L'.') ++pb;
    }
    return 0;
}

void RemoveTree(const std::wstring& dir) {
    if (!Exists(dir)) return;
    std::wstring from = dir + L'\0';  // double-null terminated
    SHFILEOPSTRUCTW op{};
    op.wFunc = FO_DELETE;
    op.pFrom = from.c_str();
    op.fFlags = FOF_NO_UI;
    SHFileOperationW(&op);
}

// GET over HTTPS into `body` or `file`. WinHTTP follows GitHub's redirect to its download host.
bool HttpGet(const std::wstring& url, const wchar_t* accept, std::string* body, HANDLE file, std::wstring& err) {
    wchar_t host[256], path[2048], extra[2048];
    URL_COMPONENTS uc{sizeof(uc)};
    uc.lpszHostName = host;
    uc.dwHostNameLength = ARRAYSIZE(host);
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = ARRAYSIZE(path);
    uc.lpszExtraInfo = extra;
    uc.dwExtraInfoLength = ARRAYSIZE(extra);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc) || uc.nScheme != INTERNET_SCHEME_HTTPS) {
        err = L"Bad download address: " + url;
        return false;
    }

    std::wstring agent = L"LiteWallpaper/" + AppVersion();
    HINTERNET session = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nullptr, nullptr, 0);
    if (!session) session = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nullptr, nullptr, 0);
    HINTERNET conn = session ? WinHttpConnect(session, host, uc.nPort, 0) : nullptr;
    HINTERNET req = conn ? WinHttpOpenRequest(conn, L"GET", (std::wstring(path) + extra).c_str(), nullptr, WINHTTP_NO_REFERER,
                                              WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)
                         : nullptr;
    bool ok = false;
    if (req) {
        WinHttpSetTimeouts(session, 15000, 15000, 30000, 60000);
        std::wstring headers = std::wstring(L"Accept: ") + accept + L"\r\nX-GitHub-Api-Version: 2022-11-28";
        DWORD status = 0, size = sizeof(status);
        if (!WinHttpSendRequest(req, headers.c_str(), (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
            !WinHttpReceiveResponse(req, nullptr)) {
            err = L"Couldn't reach GitHub (error " + std::to_wstring(GetLastError()) + L").";
        } else if (!WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                        &status, &size, WINHTTP_NO_HEADER_INDEX) || status != 200) {
            err = status == 404 ? L"No release has been published yet."
                                : L"GitHub replied with HTTP " + std::to_wstring(status) + L".";
        } else {
            std::vector<char> buf(64 * 1024);
            ok = true;
            for (;;) {
                DWORD got = 0;
                if (!WinHttpReadData(req, buf.data(), (DWORD)buf.size(), &got)) {
                    err = L"The download was interrupted.";
                    ok = false;
                    break;
                }
                if (!got) break;
                if (body) body->append(buf.data(), got);
                DWORD written;
                if (file && (!WriteFile(file, buf.data(), got, &written, nullptr) || written != got)) {
                    err = L"Couldn't save the download.";
                    ok = false;
                    break;
                }
            }
        }
    } else {
        err = L"Couldn't reach GitHub (error " + std::to_wstring(GetLastError()) + L").";
    }
    if (req) WinHttpCloseHandle(req);
    if (conn) WinHttpCloseHandle(conn);
    if (session) WinHttpCloseHandle(session);
    return ok;
}

bool FetchLatest(Release& rel, std::wstring& err) {
    std::string body;
    if (!HttpGet(L"https://api.github.com/repos/" LW_REPO "/releases/latest", L"application/vnd.github+json", &body,
                 nullptr, err))
        return false;
    Json root;
    std::string perr;
    if (!Json::Parse(body, root, perr)) {
        err = L"GitHub's reply couldn't be read.";
        return false;
    }
    std::string tag = root["tag_name"].Str("");
    if (!tag.empty() && (tag[0] == 'v' || tag[0] == 'V')) tag.erase(0, 1);
    rel.version = Utf8ToWide(tag);
    for (auto& a : root["assets"].arr) {
        std::string name = a["name"].Str("");
        if (name.rfind("LiteWallpaper-", 0) != 0 || name.size() < 4 || name.compare(name.size() - 4, 4, ".zip")) continue;
        rel.zipUrl = Utf8ToWide(a["browser_download_url"].Str(""));
        std::string digest = a["digest"].Str("");
        if (digest.rfind("sha256:", 0) == 0) {
            rel.sha256 = digest.substr(7);
            for (auto& c : rel.sha256) c = (char)tolower((unsigned char)c);
        }
        break;
    }
    if (rel.version.empty() || rel.zipUrl.empty()) {
        err = L"The latest release has no LiteWallpaper zip.";
        return false;
    }
    return true;
}

std::string Sha256File(const std::wstring& path) {
    std::string hex;
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (f != INVALID_HANDLE_VALUE && BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0)) &&
        BCRYPT_SUCCESS(BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0))) {
        std::vector<UCHAR> buf(64 * 1024);
        DWORD got = 0;
        bool ok = true;
        while (ok && ReadFile(f, buf.data(), (DWORD)buf.size(), &got, nullptr) && got)
            ok = BCRYPT_SUCCESS(BCryptHashData(hash, buf.data(), got, 0));
        UCHAR digest[32];
        if (ok && BCRYPT_SUCCESS(BCryptFinishHash(hash, digest, sizeof(digest), 0))) {
            char two[3];
            for (UCHAR b : digest) {
                sprintf_s(two, "%02x", b);
                hex += two;
            }
        }
    }
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
    return hex;
}

// Windows 10 (1803) and later ship bsdtar, which unpacks zips.
bool Unzip(const std::wstring& zip, const std::wstring& to, std::wstring& err) {
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, ARRAYSIZE(sys));
    std::wstring tar = std::wstring(sys) + L"\\tar.exe";
    std::wstring cmd = L"\"" + tar + L"\" -xf \"" + zip + L"\" -C \"" + to + L"\"";
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(tar.c_str(), cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS,
                        nullptr, to.c_str(), &si, &pi)) {
        err = L"Windows' tar.exe wasn't found, so the update couldn't be unpacked.";
        return false;
    }
    DWORD code = 1;
    if (WaitForSingleObject(pi.hProcess, 120000) == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
    else TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (code != 0) err = L"The update couldn't be unpacked.";
    return code == 0;
}

// Downloads and unpacks a release into %APPDATA%\LiteWallpaper\update\<version>. Returns that folder.
std::wstring Download(const Release& rel, std::wstring& err) {
    std::wstring dir = DataDir() + L"\\update";
    RemoveTree(dir);
    CreateDirectoryW(dir.c_str(), nullptr);
    std::wstring zip = dir + L"\\LiteWallpaper-" + rel.version + L".zip";
    HANDLE f = CreateFileW(zip.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        err = L"Couldn't save the download to " + dir + L".";
        return L"";
    }
    bool ok = HttpGet(rel.zipUrl, L"application/octet-stream", nullptr, f, err);
    CloseHandle(f);
    if (ok && !rel.sha256.empty() && Sha256File(zip) != rel.sha256) {
        err = L"The download was damaged (its checksum doesn't match).";
        ok = false;
    }
    std::wstring staged = dir + L"\\" + rel.version;
    if (ok) {
        CreateDirectoryW(staged.c_str(), nullptr);
        ok = Unzip(zip, staged, err);
    }
    if (ok && !Exists(staged + L"\\" + kExeName)) {
        err = L"The release zip has no LiteWallpaper.exe.";
        ok = false;
    }
    DeleteFileW(zip.c_str());
    if (!ok) {
        RemoveTree(dir);
        return L"";
    }
    return staged;
}

DWORD WINAPI Worker(LPVOID) {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_LOWEST);
    Release rel;
    std::wstring err, staged;
    bool newer = false;
    if (FetchLatest(rel, err)) {
        newer = CompareVersions(rel.version, AppVersion()) > 0;
        if (newer && Upd.download) staged = Download(rel, err);
    }
    {
        std::lock_guard<std::mutex> g(Upd.lock);
        Upd.latest = rel;
        Upd.found = newer;
        Upd.error = err;
        if (!staged.empty()) {
            Upd.staged = staged;
            Upd.needsAdmin = false;
        }
    }
    if (!err.empty()) Log(L"Update check: %s", err.c_str());
    Upd.busy = false;
    PostMessageW(g_mainWnd, WM_APP_UPDATE, 0, 0);
    return 0;
}

void StartWorker(bool userAsked, bool download) {
    if (Upd.busy.exchange(true)) return;
    Upd.userAsked = userAsked;
    Upd.download = download;
    HANDLE t = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr);
    if (t) CloseHandle(t);
    else Upd.busy = false;
}

bool CanWrite(const std::wstring& dir) {
    HANDLE f = CreateFileW((dir + L"\\.update-test").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    CloseHandle(f);
    return true;
}

// Copies everything except the exe. The settings template next to the exe is left alone.
void CopyFiles(const std::wstring& from, const std::wstring& to, bool top) {
    CreateDirectoryW(to.c_str(), nullptr);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((from + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        std::wstring src = from + L"\\" + fd.cFileName, dst = to + L"\\" + fd.cFileName;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            CopyFiles(src, dst, false);
        } else if (!(top && (!_wcsicmp(fd.cFileName, kExeName) || (!_wcsicmp(fd.cFileName, L"wallpaper.ini") && Exists(dst))))) {
            if (!CopyFileW(src.c_str(), dst.c_str(), FALSE)) Log(L"Update: couldn't replace %s (%u)", dst.c_str(), GetLastError());
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

// Installed with the setup: point Settings > Apps at the new version. Only the uninstall entry
// whose folder is `dir` is touched (per-user installs are in HKCU, all-users ones in HKLM).
void UpdateUninstallEntry(const std::wstring& dir, const std::wstring& version) {
    for (HKEY hive : {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}) {
        HKEY key;
        if (RegOpenKeyExW(hive, LW_UNINSTALL_KEY, 0, KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS)
            continue;
        wchar_t location[MAX_PATH * 2] = L"";
        DWORD size = sizeof(location);
        if (RegGetValueW(key, nullptr, L"InstallLocation", RRF_RT_REG_SZ, nullptr, location, &size) == ERROR_SUCCESS) {
            std::wstring loc = location;
            while (!loc.empty() && loc.back() == L'\\') loc.pop_back();
            if (!_wcsicmp(loc.c_str(), dir.c_str()))
                RegSetValueExW(key, L"DisplayVersion", 0, REG_SZ, (const BYTE*)version.c_str(),
                               (DWORD)((version.size() + 1) * sizeof(wchar_t)));
        }
        RegCloseKey(key);
    }
}

// Installs an unpacked release over `dir`, whose exe is called `exeName`. The running exe can't be
// overwritten but can be renamed, so it moves aside to <name>.old and is deleted on the next start.
bool InstallFiles(const std::wstring& staged, const std::wstring& dir, const std::wstring& exeName,
                  const std::wstring& version) {
    CopyFiles(staged, dir, true);
    std::wstring exe = dir + L"\\" + exeName, old = exe + L".old";
    DeleteFileW(old.c_str());
    if (Exists(old)) old += std::to_wstring(GetTickCount64());  // still running for another user
    if (Exists(exe) && !MoveFileExW(exe.c_str(), old.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        Log(L"Update: couldn't move %s aside (%u)", exe.c_str(), GetLastError());
        return false;
    }
    if (!CopyFileW((staged + L"\\" + kExeName).c_str(), exe.c_str(), FALSE)) {
        Log(L"Update: couldn't write %s (%u)", exe.c_str(), GetLastError());
        MoveFileExW(old.c_str(), exe.c_str(), 0);
        return false;
    }
    UpdateUninstallEntry(dir, version);
    return true;
}

}  // namespace

std::wstring AppVersion() { return Utf8ToWide(LW_VERSION); }

bool UpdatesSupported() { return strcmp(LW_VERSION, "dev") != 0; }

void StartUpdateCheck(bool userAsked) {
    if (!UpdatesSupported()) return;
    if (!userAsked) {
        std::lock_guard<std::mutex> g(Upd.lock);
        if (!Upd.staged.empty()) return;  // already downloaded, waiting to be installed
    }
    StartWorker(userAsked, !userAsked);  // asked from the menu: ask before downloading
}

void OnUpdateCheckDone(HWND owner) {
    std::unique_lock<std::mutex> g(Upd.lock);
    bool userAsked = Upd.userAsked, downloaded = Upd.download, found = Upd.found;
    std::wstring err = Upd.error, version = Upd.latest.version, staged = Upd.staged;
    g.unlock();
    Upd.userAsked = false;
    if (!userAsked) return;  // automatic: the main loop installs it once nothing is in the way

    const wchar_t* title = L"LiteWallpaper updates";
    if (!err.empty()) {
        MessageBoxW(owner, (L"Couldn't update.\n\n" + err).c_str(), title, MB_OK | MB_ICONWARNING);
    } else if (!found) {
        MessageBoxW(owner, (L"You have the latest version (" + AppVersion() + L").").c_str(), title, MB_OK | MB_ICONINFORMATION);
    } else if (!downloaded) {
        std::wstring q = L"LiteWallpaper " + version + L" is available. You have " + AppVersion() +
                         L".\n\nDownload it and restart LiteWallpaper now?";
        if (MessageBoxW(owner, q.c_str(), title, MB_YESNO | MB_ICONQUESTION) == IDYES) StartWorker(true, true);
    } else if (!staged.empty()) {
        InstallStagedUpdate(owner, true);
    }
}

bool UpdateBusy() { return Upd.busy; }

bool UpdateWaiting() {
    std::lock_guard<std::mutex> g(Upd.lock);
    return !Upd.busy && !Upd.staged.empty() && !Upd.needsAdmin;
}

std::wstring UpdateMenuText() {
    std::lock_guard<std::mutex> g(Upd.lock);
    if (Upd.busy) return Upd.download ? L"Downloading update..." : L"Checking for updates...";
    if (!Upd.staged.empty()) return L"Install update " + Upd.latest.version + (Upd.needsAdmin ? L" (needs admin)..." : L"");
    return L"Check for updates";
}

void UpdateMenuCommand(HWND owner) {
    if (UpdateBusy()) return;
    bool staged;
    {
        std::lock_guard<std::mutex> g(Upd.lock);
        staged = !Upd.staged.empty();
    }
    if (staged) InstallStagedUpdate(owner, true);
    else StartUpdateCheck(true);
}

bool InstallStagedUpdate(HWND owner, bool interactive) {
    std::wstring staged, version;
    {
        std::lock_guard<std::mutex> g(Upd.lock);
        staged = Upd.staged;
        version = Upd.latest.version;
    }
    if (staged.empty() || !Exists(staged + L"\\" + kExeName)) return false;
    std::wstring exe = OwnExePath(), dir = ExeDir(), exeName = FileName(exe);

    if (CanWrite(dir)) {
        if (!InstallFiles(staged, dir, exeName, version)) {
            if (interactive) MessageBoxW(owner, L"Couldn't install the update. See LiteWallpaper.log in your settings folder.",
                                         L"LiteWallpaper updates", MB_OK | MB_ICONWARNING);
            std::lock_guard<std::mutex> g(Upd.lock);
            Upd.staged.clear();  // don't retry every second; the next check downloads it again
            return false;
        }
    } else if (!interactive) {
        // Installed somewhere only admins can write (Program Files): wait for the user to say so.
        bool first;
        {
            std::lock_guard<std::mutex> g(Upd.lock);
            first = !Upd.needsAdmin;
            Upd.needsAdmin = true;
        }
        if (first)
            ShowNotice(L"LiteWallpaper " + version + L" is ready",
                       L"Right-click the tray icon and choose \"Install update\". It needs admin rights.");
        return false;
    } else {
        std::wstring args = L"--install-update \"" + staged + L"\" \"" + dir + L"\" \"" + exeName + L"\" " + version;
        SHELLEXECUTEINFOW sei{sizeof(sei)};
        sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        sei.hwnd = owner;
        sei.lpVerb = L"runas";
        sei.lpFile = exe.c_str();
        sei.lpParameters = args.c_str();
        sei.nShow = SW_HIDE;
        if (!ShellExecuteExW(&sei)) return false;  // the admin prompt was cancelled
        DWORD code = 1;
        if (sei.hProcess) {
            WaitForSingleObject(sei.hProcess, 120000);
            GetExitCodeProcess(sei.hProcess, &code);
            CloseHandle(sei.hProcess);
        }
        if (code != 0) {
            MessageBoxW(owner, L"Couldn't install the update.", L"LiteWallpaper updates", MB_OK | MB_ICONWARNING);
            return false;
        }
    }

    // Start the new version; it waits for this process to exit before taking over.
    std::wstring cmd = L"\"" + exe + L"\" --updated " + std::to_wstring(GetCurrentProcessId());
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, dir.c_str(), &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    Log(L"Updating to %s", version.c_str());
    DestroyWindow(g_mainWnd);
    return true;
}

int InstallUpdateCommand(const std::wstring& staged, const std::wstring& dir, const std::wstring& exeName,
                         const std::wstring& version) {
    if (exeName.empty() || exeName.find_first_of(L"\\/") != std::wstring::npos) return 2;
    return InstallFiles(staged, dir, exeName, version) ? 0 : 1;
}

void FinishUpdate(DWORD oldPid) {
    if (HANDLE old = OpenProcess(SYNCHRONIZE, FALSE, oldPid)) {
        WaitForSingleObject(old, 15000);
        CloseHandle(old);
    }
    RemoveTree(DataDir() + L"\\update");
}

void ShowUpdatedNotice() { ShowNotice(L"LiteWallpaper updated", L"Now running version " + AppVersion() + L"."); }

// Leftovers of earlier updates: the renamed old exe (once nobody runs it) and unused downloads.
void CleanUpOldUpdate() {
    std::wstring dir = ExeDir();
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*.exe.old*").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do DeleteFileW((dir + L"\\" + fd.cFileName).c_str());
        while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveTree(DataDir() + L"\\update");
}
