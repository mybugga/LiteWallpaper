// LiteWallpaper.exe --render <wallpaper> <out.bgra> [width height seconds fps cssWidth]
// Draws a wallpaper offscreen at an exact frame rate, with the same code that draws it on the
// desktop, and writes the frames one after another as raw BGRA pixels. scripts\make-previews.ps1
// turns them into the preview GIFs in the README, scripts\make-android-thumbs.py into the phone app's
// thumbnails. Particles are sized as on a screen cssWidth particles.js pixels wide (default 1920).
#include "app.h"
#include <algorithm>

double g_clockOverride = -1;

int RenderFrames(int argc, wchar_t** argv) {
    if (argc < 4) return 1;
    std::wstring file = ResolvePath(argv[2]), out = argv[3];
    UINT w = argc > 4 ? (UINT)_wtoi(argv[4]) : 960, h = argc > 5 ? (UINT)_wtoi(argv[5]) : 540;
    double seconds = argc > 6 ? _wtof(argv[6]) : 5, fps = argc > 7 ? _wtof(argv[7]) : 30;
    double cssWidth = argc > 8 ? _wtof(argv[8]) : 1920;
    if (!w || !h || seconds <= 0 || fps <= 0 || cssWidth <= 0) return 1;

    Gpu gpu;
    if (!gpu.Init()) return 2;
    Config cfg = LoadConfig();
    std::wstring err;
    auto src = CreateSource(gpu, file, cfg, err);
    if (!src) {
        Log(L"--render %s: %s", file.c_str(), err.c_str());
        return 3;
    }

    D3D11_TEXTURE2D_DESC td{};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    Screen s;
    ComPtr<ID3D11Texture2D> target, staging;
    if (FAILED(gpu.dev->CreateTexture2D(&td, nullptr, &target)) ||
        FAILED(gpu.dev->CreateRenderTargetView(target.Get(), nullptr, &s.rtv)))
        return 2;
    td.BindFlags = 0;
    td.Usage = D3D11_USAGE_STAGING;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(gpu.dev->CreateTexture2D(&td, nullptr, &staging))) return 2;
    s.bw = w;
    s.bh = h;
    s.cfg.fit = Fit::Cover;
    s.previewScale = (float)(w / cssWidth);  // particles look as they do on a screen that wide

    HANDLE f = CreateFileW(out.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return 4;

    // A second's run-up first, so smoke, embers and particles have spread out.
    const double start = 100.0;
    const int warmup = (int)fps, frames = (int)(seconds * fps + 0.5);
    src->active = true;
    src->SetActive(true, start);
    std::vector<BYTE> row(w * 4);
    SYSTEMTIME now;
    GetLocalTime(&now);
    const double clockStart = now.wHour * 3600.0 + now.wMinute * 60.0 + now.wSecond + now.wMilliseconds / 1000.0;
    for (int i = -warmup; i < frames; ++i) {
        double t = start + (i + warmup) / fps;
        g_clockOverride = clockStart + (t - start);  // clocks tick with the frames, not the wall clock
        src->Update(t, t);
        src->Draw(gpu, s);
        if (i < 0) continue;
        gpu.ctx->CopyResource(staging.Get(), target.Get());
        D3D11_MAPPED_SUBRESOURCE m;
        if (FAILED(gpu.ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &m))) break;
        DWORD written;
        for (UINT y = 0; y < h; ++y) {
            const BYTE* p = (const BYTE*)m.pData + (size_t)y * m.RowPitch;
            std::copy(p, p + w * 4, row.begin());
            for (UINT x = 0; x < w; ++x) row[x * 4 + 3] = 255;  // opaque
            WriteFile(f, row.data(), w * 4, &written, nullptr);
        }
        gpu.ctx->Unmap(staging.Get(), 0);
    }
    CloseHandle(f);
    src.reset();
    gpu.Reset();
    return 0;
}
