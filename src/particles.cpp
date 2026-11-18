// Native port of particles.js by Vincent Garreau (MIT license):
// https://github.com/VincentGarreau/particles.js
//
// Reads particles.js JSON configs unchanged and follows the library's behaviour: shapes, linked
// lines, size/opacity animation, move modes, attract, bounce, density, and the hover/click modes
// (grab, bubble, repulse, push, remove). The library steps once per 60 Hz animation frame; here
// every step is scaled by elapsed time so it looks the same at any fps.
//
// Mouse input is read by polling the cursor and button state each frame, never with a global
// mouse hook, so input everywhere else (games especially) is untouched.

#include "app.h"
#include "json.h"
#include <algorithm>
#include <cmath>
#include <random>
#include "part_vs.h"  // g_VSParticle
#include "part_ps.h"  // g_PSParticle
#include "line_vs.h"  // g_VSLine
#include "line_ps.h"  // g_PSLine
#include "bg_ps.h"    // g_PSBackground

namespace {

constexpr float kPi = 3.14159265358979f;
constexpr size_t kMaxParticles = 6000;

struct Rgb {
    float r = 1, g = 1, b = 1;
};

bool ParseHex(std::string s, Rgb& out) {
    if (!s.empty() && s[0] == '#') s.erase(0, 1);
    if (s.size() == 3) s = {s[0], s[0], s[1], s[1], s[2], s[2]};
    if (s.size() != 6) return false;
    char* end = nullptr;
    long v = strtol(s.c_str(), &end, 16);
    if (*end) return false;
    out = {((v >> 16) & 255) / 255.0f, ((v >> 8) & 255) / 255.0f, (v & 255) / 255.0f};
    return true;
}

Rgb HslToRgb(float h, float s, float l) {
    h = std::fmod(std::fmod(h, 360.0f) + 360.0f, 360.0f) / 360.0f;
    s = std::clamp(s / 100.0f, 0.0f, 1.0f);
    l = std::clamp(l / 100.0f, 0.0f, 1.0f);
    auto hue = [](float p, float q, float t) {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1.0f / 6) return p + (q - p) * 6 * t;
        if (t < 0.5f) return q;
        if (t < 2.0f / 3) return p + (q - p) * (2.0f / 3 - t) * 6;
        return p;
    };
    if (s == 0) return {l, l, l};
    float q = l < 0.5f ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    return {hue(p, q, h + 1.0f / 3), hue(p, q, h), hue(p, q, h - 1.0f / 3)};
}

std::wstring Widen(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), w.data(), n);
    return w;
}

// Image paths in a config are relative to the config file. Web URLs can't be used offline.
std::wstring ResolveAsset(const std::string& src, const std::wstring& dir) {
    if (src.empty() || src.rfind("http://", 0) == 0 || src.rfind("https://", 0) == 0 || src.rfind("data:", 0) == 0)
        return L"";
    std::wstring p = Widen(src);
    std::replace(p.begin(), p.end(), L'/', L'\\');
    bool absolute = (p.size() > 1 && p[1] == L':') || (p.size() > 1 && p[0] == L'\\' && p[1] == L'\\');
    return absolute ? p : dir + L"\\" + p;
}

std::vector<std::string> ReadModes(const Json& mode) {
    std::vector<std::string> out;
    if (mode.type == Json::String) out.push_back(mode.str);
    for (auto& m : mode.arr)
        if (m.type == Json::String) out.push_back(m.str);
    return out;
}

bool HasMode(const std::vector<std::string>& modes, const char* name) {
    return std::find(modes.begin(), modes.end(), name) != modes.end();
}

enum class Shape { Circle, Edge, Triangle, Polygon, Star, Image };

bool ParseShape(const std::string& s, Shape& out) {
    if (s == "circle") out = Shape::Circle;
    else if (s == "edge") out = Shape::Edge;
    else if (s == "triangle") out = Shape::Triangle;
    else if (s == "polygon") out = Shape::Polygon;
    else if (s == "star") out = Shape::Star;
    else if (s == "image") out = Shape::Image;
    else return false;
    return true;
}

// The particles.js config, with the library's own defaults for anything left out.
struct Settings {
    int number = 400;
    bool density = true;
    float densityArea = 800;
    Json color;
    std::vector<Shape> shapes{Shape::Circle};
    float strokeWidth = 0;
    Rgb strokeColor{1, 0, 0};
    float sides = 5;
    std::wstring imageSrc;
    float imageRatio = 1;
    float opacity = 1, opacitySpeed = 2, opacityMin = 0;
    bool opacityRandom = false, opacityAnim = false, opacitySync = false;
    float size = 20, sizeSpeed = 20, sizeMin = 0;
    bool sizeRandom = false, sizeAnim = false, sizeSync = false;
    bool lines = true;
    float lineDistance = 100, lineOpacity = 1, lineWidth = 1;
    Rgb lineColor;
    bool move = true, moveRandom = false, straight = false, outBounce = false, bounce = false;
    float speed = 2, baseVx = 0, baseVy = 0;
    bool attract = false;
    float rotateX = 3000, rotateY = 3000;

    bool detectWindow = false;
    bool hoverOn = true, clickOn = true;
    std::vector<std::string> hover{"grab"}, click{"push"};
    float grabDistance = 100, grabOpacity = 1;
    float bubbleDistance = 200, bubbleSize = 80, bubbleDuration = 0.4f, bubbleOpacity = NAN;
    float repulseDistance = 200, repulseDuration = 0.4f;
    int pushNb = 4, removeNb = 2;
    bool retina = false;

    Rgb bgColor{0, 0, 0};
    std::wstring bgImage;
    std::string bgSize = "cover", bgPosition = "50% 50%";
    bool bgRepeat = false;

    void Load(const Json& root, const std::wstring& dir) {
        const Json& p = root["particles"];
        number = (int)p["number"]["value"].Num(number);
        density = p["number"]["density"]["enable"].Flag(density);
        densityArea = (float)p["number"]["density"]["value_area"].Num(densityArea);
        if (p["color"].Has("value")) color = p["color"]["value"];
        else color.type = Json::String, color.str = "#fff";

        const Json& sh = p["shape"];
        std::vector<Shape> types;
        Shape t;
        if (ParseShape(sh["type"].Str(""), t)) types.push_back(t);
        for (auto& v : sh["type"].arr)
            if (ParseShape(v.Str(""), t)) types.push_back(t);
        if (!types.empty()) shapes = types;
        strokeWidth = (float)sh["stroke"]["width"].Num(strokeWidth);
        ParseHex(sh["stroke"]["color"].Str("#ff0000"), strokeColor);
        sides = std::max(3.0f, (float)sh["polygon"]["nb_sides"].Num(sides));
        imageSrc = ResolveAsset(sh["image"]["src"].Str(""), dir);
        double iw = sh["image"]["width"].Num(100), ih = sh["image"]["height"].Num(100);
        imageRatio = ih > 0 && iw > 0 ? (float)(iw / ih) : 1.0f;

        const Json& op = p["opacity"];
        opacity = (float)op["value"].Num(opacity);
        opacityRandom = op["random"].Flag(opacityRandom);
        opacityAnim = op["anim"]["enable"].Flag(opacityAnim);
        opacitySpeed = (float)op["anim"]["speed"].Num(opacitySpeed);
        opacityMin = (float)op["anim"]["opacity_min"].Num(opacityMin);
        opacitySync = op["anim"]["sync"].Flag(opacitySync);

        const Json& sz = p["size"];
        size = (float)sz["value"].Num(size);
        sizeRandom = sz["random"].Flag(sizeRandom);
        sizeAnim = sz["anim"]["enable"].Flag(sizeAnim);
        sizeSpeed = (float)sz["anim"]["speed"].Num(sizeSpeed);
        sizeMin = (float)sz["anim"]["size_min"].Num(sizeMin);
        sizeSync = sz["anim"]["sync"].Flag(sizeSync);

        const Json& ll = p["line_linked"];
        lines = ll["enable"].Flag(lines);
        lineDistance = (float)ll["distance"].Num(lineDistance);
        ParseHex(ll["color"].Str("#fff"), lineColor);
        lineOpacity = (float)ll["opacity"].Num(lineOpacity);
        lineWidth = (float)ll["width"].Num(lineWidth);

        const Json& mv = p["move"];
        move = mv["enable"].Flag(move);
        speed = (float)mv["speed"].Num(speed);
        std::string dirName = mv["direction"].Str("none");
        // Same table as particles.js, including its lopsided bottom-left.
        struct { const char* name; float x, y; } dirs[] = {
            {"top", 0, -1},     {"top-right", 0.5f, -0.5f}, {"right", 1, 0},  {"bottom-right", 0.5f, 0.5f},
            {"bottom", 0, 1},   {"bottom-left", -0.5f, 1},  {"left", -1, 0},  {"top-left", -0.5f, -0.5f}};
        for (auto& d : dirs)
            if (dirName == d.name) baseVx = d.x, baseVy = d.y;
        moveRandom = mv["random"].Flag(moveRandom);
        straight = mv["straight"].Flag(straight);
        outBounce = mv["out_mode"].Str("out") == "bounce";
        bounce = mv["bounce"].Flag(bounce);
        attract = mv["attract"]["enable"].Flag(attract);
        rotateX = (float)mv["attract"]["rotateX"].Num(rotateX);
        rotateY = (float)mv["attract"]["rotateY"].Num(rotateY);

        const Json& in = root["interactivity"];
        detectWindow = in["detect_on"].Str("canvas") == "window";
        hoverOn = in["events"]["onhover"]["enable"].Flag(hoverOn);
        if (in["events"]["onhover"].Has("mode")) hover = ReadModes(in["events"]["onhover"]["mode"]);
        clickOn = in["events"]["onclick"]["enable"].Flag(clickOn);
        if (in["events"]["onclick"].Has("mode")) click = ReadModes(in["events"]["onclick"]["mode"]);
        const Json& md = in["modes"];
        grabDistance = (float)md["grab"]["distance"].Num(grabDistance);
        grabOpacity = (float)md["grab"]["line_linked"]["opacity"].Num(grabOpacity);
        bubbleDistance = (float)md["bubble"]["distance"].Num(bubbleDistance);
        bubbleSize = (float)md["bubble"]["size"].Num(bubbleSize);
        bubbleDuration = (float)md["bubble"]["duration"].Num(bubbleDuration);
        bubbleOpacity = (float)md["bubble"]["opacity"].Num(NAN);
        repulseDistance = (float)md["repulse"]["distance"].Num(repulseDistance);
        repulseDuration = (float)md["repulse"]["duration"].Num(repulseDuration);
        pushNb = (int)md["push"]["particles_nb"].Num(pushNb);
        removeNb = (int)md["remove"]["particles_nb"].Num(removeNb);
        retina = root["retina_detect"].Flag(retina);

        // The particles.js demo page keeps the page background here.
        const Json& bg = root["config_demo"];
        ParseHex(bg["background_color"].Str("#000000"), bgColor);
        bgImage = ResolveAsset(bg["background_image"].Str(""), dir);
        bgSize = bg["background_size"].Str(bgSize);
        bgPosition = bg["background_position"].Str(bgPosition);
        std::string rep = bg["background_repeat"].Str("no-repeat");
        bgRepeat = rep == "repeat";
    }
};

struct Particle {
    float x = 0, y = 0, vx = 0, vy = 0, vxi = 0, vyi = 0;
    float radius = 0, opacity = 1, vs = 0, vo = 0;
    float radiusBubble = -1, opacityBubble = -1;  // < 0 = not set
    bool sizeUp = false, opacityUp = false;
    Rgb color;
    Shape shape = Shape::Circle;
};

struct LineInst {
    float x0, y0, x1, y1;
    float r, g, b, a;
    float width;
};

struct PartInst {
    float cx, cy, hx, hy;
    float fill[4];
    float stroke[4];
    float shape[4];  // type, R, Rin, sides
    float param[4];  // rotation, image flag
};

struct Sim {
    const Screen* screen = nullptr;
    RECT rc{};
    float w = 0, h = 0;     // canvas size in simulation pixels
    float drawScale = 1;    // simulation pixels -> back buffer pixels
    float pxratio = 1;
    bool retinaOn = false;
    Settings s;             // with retina scaling applied
    std::vector<Particle> ps;
    std::vector<LineInst> lines;

    bool mouseIn = false;
    float mx = 0, my = 0, clickX = 0, clickY = 0;
    double clickTime = 0, repulseUntil = 0;
    bool bubbleClicking = false, bubbleDurationEnd = false, repulseClicking = false;
};

}  // namespace

class ParticleSource final : public Source {
public:
    bool Load(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& err) {
        interval_ = 1.0 / cfg.fps;
        Json root;
        if (!LoadParticleJson(path, root, err)) return false;
        std::wstring dir = path.substr(0, path.find_last_of(L"\\/"));
        cfg_.Load(root, dir);

        if (!CreateGpuObjects(gpu)) {
            err = L"Could not create particle renderer";
            return false;
        }
        if (!cfg_.bgImage.empty()) {
            bg_ = std::make_unique<Picture>();
            std::wstring e;
            if (!bg_->Load(gpu, cfg_.bgImage, e)) {
                Log(L"Background %s: %s", cfg_.bgImage.c_str(), e.c_str());
                bg_.reset();
            }
        }
        if (std::find(cfg_.shapes.begin(), cfg_.shapes.end(), Shape::Image) != cfg_.shapes.end() && !cfg_.imageSrc.empty()) {
            image_ = std::make_unique<Picture>();
            std::wstring e;
            if (!image_->Load(gpu, cfg_.imageSrc, e)) {
                Log(L"Particle image %s: %s", cfg_.imageSrc.c_str(), e.c_str());
                image_.reset();
            }
        }
        interactive_ = (cfg_.hoverOn && !cfg_.hover.empty()) || (cfg_.clickOn && !cfg_.click.empty());
        return true;
    }

    double NextDue() const override { return next_; }

    void SetActive(bool active, double now) override {
        if (!active) return;
        next_ = now;
        last_ = now;
        if (bg_) bg_->Restart(now);
        if (image_) image_->Restart(now);
    }

    bool Update(double now, double) override {
        double dt = std::clamp(now - last_, 0.0, 0.1);
        last_ = now;
        next_ += interval_;
        if (next_ < now) next_ = now + interval_;

        POINT pt{};
        bool havePt = interactive_ && GetCursorPos(&pt);
        bool overDesktop = false;
        if (havePt) {
            HWND hit = WindowFromPoint(pt);
            HWND root = hit ? GetAncestor(hit, GA_ROOT) : nullptr;
            wchar_t cls[32] = L"";
            if (root) GetClassNameW(root, cls, ARRAYSIZE(cls));
            overDesktop = !wcscmp(cls, L"Progman") || !wcscmp(cls, L"WorkerW");
        }
        int button = GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
        SHORT state = havePt ? GetAsyncKeyState(button) : 0;
        bool down = (state & 0x8000) != 0;
        // Bit 0 catches a click that started and ended between two frames.
        bool pressed = (down && !buttonDown_) || (!down && (state & 1));
        buttonDown_ = down;

        for (auto& sim : sims_) {
            sim->mouseIn = havePt && PtInRect(&sim->rc, pt) && (sim->s.detectWindow || overDesktop);
            if (sim->mouseIn) {
                sim->mx = (pt.x - sim->rc.left) / sim->drawScale;
                sim->my = (pt.y - sim->rc.top) / sim->drawScale;
                if (pressed && sim->s.clickOn) Click(*sim, now);
            }
            Step(*sim, (float)dt, now);
        }
        if (bg_) bg_->Advance(now);
        if (image_) image_->Advance(now);
        return true;
    }

    void Draw(Gpu& gpu, Screen& s) override {
        Sim& sim = SimFor(s);
        Render(gpu, s, sim);
    }

private:
    float Rand() { return dist_(rng_); }

    // ---------------------------------------------------------------- simulation

    Sim& SimFor(Screen& s) {
        for (auto& sim : sims_)
            if (sim->screen == &s) return *sim;
        auto sim = std::make_unique<Sim>();
        sim->screen = &s;
        sim->rc = s.rc;
        float dpi = s.hwnd ? GetDpiForWindow(s.hwnd) / 96.0f : 1.0f;
        if (dpi <= 0) dpi = 1;
        sim->s = cfg_;
        // retina_detect: simulate in device pixels with sizes scaled up, exactly like the library.
        // Otherwise simulate in CSS pixels and scale the drawing, the way a browser would.
        if (cfg_.retina && dpi > 1) {
            sim->retinaOn = true;
            sim->pxratio = dpi;
            Settings& c = sim->s;
            for (float* v : {&c.size, &c.sizeSpeed, &c.speed, &c.lineDistance, &c.grabDistance, &c.bubbleDistance,
                             &c.lineWidth, &c.bubbleSize, &c.repulseDistance})
                *v *= dpi;
        } else {
            sim->drawScale = dpi;
        }
        sim->w = s.bw / sim->drawScale;
        sim->h = s.bh / sim->drawScale;

        for (int i = 0; i < sim->s.number && sim->ps.size() < kMaxParticles; ++i) sim->ps.push_back(NewParticle(*sim, false, 0, 0));
        if (sim->s.density) {
            float area = sim->w * sim->h / 1000;
            if (sim->retinaOn) area /= sim->pxratio * 2;
            float wanted = area * sim->s.number / std::max(sim->s.densityArea, 1.0f);
            float missing = sim->ps.size() - wanted;
            if (missing < 0) Push(*sim, (int)std::ceil(-missing), false);
            else sim->ps.erase(sim->ps.begin(), sim->ps.begin() + std::min(sim->ps.size(), (size_t)missing));
        }
        sims_.push_back(std::move(sim));
        return *sims_.back();
    }

    Particle NewParticle(Sim& sim, bool atPos, float px, float py) {
        const Settings& s = sim.s;
        Particle p;
        p.radius = (s.sizeRandom ? Rand() : 1) * s.size;
        if (s.sizeAnim) {
            p.vs = s.sizeSpeed / 100;
            if (!s.sizeSync) p.vs *= Rand();
        }
        p.x = atPos ? px : Rand() * sim.w;
        p.y = atPos ? py : Rand() * sim.h;
        if (p.x > sim.w - p.radius * 2) p.x -= p.radius;
        else if (p.x < p.radius * 2) p.x += p.radius;
        if (p.y > sim.h - p.radius * 2) p.y -= p.radius;
        else if (p.y < p.radius * 2) p.y += p.radius;

        if (s.bounce) {  // avoid starting on top of another particle
            for (int tries = 0; tries < 50; ++tries) {
                bool overlap = false;
                for (auto& o : sim.ps) {
                    float dx = p.x - o.x, dy = p.y - o.y;
                    if (std::sqrt(dx * dx + dy * dy) <= p.radius + o.radius) {
                        overlap = true;
                        break;
                    }
                }
                if (!overlap) break;
                p.x = Rand() * sim.w;
                p.y = Rand() * sim.h;
            }
        }

        const Json& c = s.color;
        if (c.type == Json::Array && !c.arr.empty()) {
            ParseHex(c.arr[std::min(c.arr.size() - 1, (size_t)(Rand() * c.arr.size()))].Str("#fff"), p.color);
        } else if (c.type == Json::Object) {
            if (c.Has("r")) p.color = {(float)c["r"].Num(255) / 255, (float)c["g"].Num(255) / 255, (float)c["b"].Num(255) / 255};
            else if (c.Has("h")) p.color = HslToRgb((float)c["h"].Num(0), (float)c["s"].Num(0), (float)c["l"].Num(100));
        } else if (c.Str("") == "random") {
            p.color = {std::floor(Rand() * 256) / 255, std::floor(Rand() * 256) / 255, std::floor(Rand() * 256) / 255};
        } else {
            ParseHex(c.Str("#fff"), p.color);
        }

        p.opacity = (s.opacityRandom ? Rand() : 1) * s.opacity;
        if (s.opacityAnim) {
            p.vo = s.opacitySpeed / 100;
            if (!s.opacitySync) p.vo *= Rand();
        }

        if (s.straight) {
            p.vx = s.baseVx;
            p.vy = s.baseVy;
            if (s.moveRandom) {
                p.vx *= Rand();
                p.vy *= Rand();
            }
        } else {
            p.vx = s.baseVx + Rand() - 0.5f;
            p.vy = s.baseVy + Rand() - 0.5f;
        }
        p.vxi = p.vx;
        p.vyi = p.vy;
        p.shape = s.shapes[std::min(s.shapes.size() - 1, (size_t)(Rand() * s.shapes.size()))];
        return p;
    }

    void Push(Sim& sim, int count, bool atMouse) {
        for (int i = 0; i < count && sim.ps.size() < kMaxParticles; ++i)
            sim.ps.push_back(NewParticle(sim, atMouse, sim.mx, sim.my));
    }

    void Click(Sim& sim, double now) {
        const Settings& s = sim.s;
        sim.clickX = sim.mx;
        sim.clickY = sim.my;
        sim.clickTime = now;
        for (auto& mode : s.click) {
            if (mode == "push") {
                if (s.move || s.pushNb == 1) Push(sim, s.pushNb, true);
                else if (s.pushNb > 1) Push(sim, s.pushNb, false);
            } else if (mode == "remove") {
                sim.ps.erase(sim.ps.begin(), sim.ps.begin() + std::min(sim.ps.size(), (size_t)std::max(0, s.removeNb)));
            } else if (mode == "bubble") {
                sim.bubbleClicking = true;
            } else if (mode == "repulse") {
                sim.repulseClicking = true;
                sim.repulseUntil = now + s.repulseDuration;
            }
        }
        if (g_diag) Log(L"Particles click at %.0f,%.0f -> %zu particles", sim.mx, sim.my, sim.ps.size());
    }

    void Step(Sim& sim, float dt, double now) {
        const Settings& s = sim.s;
        const float k = dt * 60;  // particles.js frames elapsed
        const bool grab = s.hoverOn && HasMode(s.hover, "grab");
        const bool bubbleHover = s.hoverOn && HasMode(s.hover, "bubble");
        const bool bubbleClick = !bubbleHover && s.clickOn && HasMode(s.click, "bubble");
        const bool repulseHover = s.hoverOn && HasMode(s.hover, "repulse");
        const bool repulseClick = !repulseHover && s.clickOn && HasMode(s.click, "repulse");
        if (sim.repulseClicking && now >= sim.repulseUntil) sim.repulseClicking = false;

        float timeSpent = (float)(now - sim.clickTime);
        if (bubbleClick && sim.bubbleClicking) {
            if (timeSpent > s.bubbleDuration) sim.bubbleDurationEnd = true;
            if (timeSpent > s.bubbleDuration * 2) sim.bubbleClicking = sim.bubbleDurationEnd = false;
        }

        sim.lines.clear();
        for (auto& p : sim.ps) {
            if (s.move) {
                float ms = s.speed / 2;
                p.x += p.vx * ms * k;
                p.y += p.vy * ms * k;
            }

            if (s.opacityAnim) {
                if (p.opacityUp) {
                    if (p.opacity >= s.opacity) p.opacityUp = false;
                    p.opacity += p.vo * k;
                } else {
                    if (p.opacity <= s.opacityMin) p.opacityUp = true;
                    p.opacity -= p.vo * k;
                }
                p.opacity = std::max(p.opacity, 0.0f);
            }
            if (s.sizeAnim) {
                if (p.sizeUp) {
                    if (p.radius >= s.size) p.sizeUp = false;
                    p.radius += p.vs * k;
                } else {
                    if (p.radius <= s.sizeMin) p.sizeUp = true;
                    p.radius -= p.vs * k;
                }
                p.radius = std::max(p.radius, 0.0f);
            }

            // Leaving the canvas: wrap to the opposite edge at a random spot.
            float r = p.radius;
            float left = s.outBounce ? r : -r, right = s.outBounce ? sim.w : sim.w + r;
            float top = s.outBounce ? r : -r, bottom = s.outBounce ? sim.h : sim.h + r;
            if (p.x - r > sim.w) p.x = left, p.y = Rand() * sim.h;
            else if (p.x + r < 0) p.x = right, p.y = Rand() * sim.h;
            if (p.y - r > sim.h) p.y = top, p.x = Rand() * sim.w;
            else if (p.y + r < 0) p.y = bottom, p.x = Rand() * sim.w;
            if (s.outBounce) {
                if (p.x + r > sim.w) p.vx = -std::fabs(p.vx);
                else if (p.x - r < 0) p.vx = std::fabs(p.vx);
                if (p.y + r > sim.h) p.vy = -std::fabs(p.vy);
                else if (p.y - r < 0) p.vy = std::fabs(p.vy);
            }

            if (grab && sim.mouseIn) {
                float dx = p.x - sim.mx, dy = p.y - sim.my, d = std::sqrt(dx * dx + dy * dy);
                if (d <= s.grabDistance) {
                    float op = s.grabOpacity - d * s.grabOpacity / s.grabDistance;
                    if (op > 0)
                        sim.lines.push_back({p.x, p.y, sim.mx, sim.my, s.lineColor.r, s.lineColor.g, s.lineColor.b, op, s.lineWidth});
                }
            }
            if (bubbleHover) BubbleHover(sim, p);
            else if (bubbleClick && sim.bubbleClicking) BubbleClick(sim, p, timeSpent);
            if (repulseHover) RepulseHover(sim, p, k);
            else if (repulseClick) RepulseClick(sim, p);
        }

        if (s.lines || s.attract) Pairs(sim, k);
    }

    void BubbleHover(Sim& sim, Particle& p) {
        const Settings& s = sim.s;
        float dx = p.x - sim.mx, dy = p.y - sim.my, d = std::sqrt(dx * dx + dy * dy);
        if (!sim.mouseIn || d > s.bubbleDistance) {
            p.opacityBubble = p.opacity;
            p.radiusBubble = p.radius;
            return;
        }
        float ratio = 1 - d / s.bubbleDistance;
        if (ratio < 0) return;
        if (s.bubbleSize != s.size) {
            if (s.bubbleSize > s.size) {
                float size = p.radius + s.bubbleSize * ratio;
                if (size >= 0) p.radiusBubble = size;
            } else {
                float size = p.radius - (p.radius - s.bubbleSize) * ratio;
                p.radiusBubble = size > 0 ? size : 0;
            }
        }
        if (!std::isnan(s.bubbleOpacity) && s.bubbleOpacity != s.opacity) {
            if (s.bubbleOpacity > s.opacity) {
                float op = s.bubbleOpacity * ratio;
                if (op > p.opacity && op <= s.bubbleOpacity) p.opacityBubble = op;
            } else {
                float op = p.opacity - (s.opacity - s.bubbleOpacity) * ratio;
                if (op < p.opacity && op >= s.bubbleOpacity) p.opacityBubble = op;
            }
        }
    }

    void BubbleClick(Sim& sim, Particle& p, float timeSpent) {
        const Settings& s = sim.s;
        float dx = p.x - sim.clickX, dy = p.y - sim.clickY, d = std::sqrt(dx * dx + dy * dy);
        auto process = [&](float bubbleParam, float particlesParam, float& bubbleValue, float value) {
            if (bubbleParam == particlesParam || std::isnan(bubbleParam)) return;
            float eased = value - timeSpent * (value - bubbleParam) / s.bubbleDuration;
            if (!sim.bubbleDurationEnd) {
                if (d <= s.bubbleDistance) {
                    float current = bubbleValue >= 0 ? bubbleValue : value;
                    if (current != bubbleParam) bubbleValue = eased;
                } else {
                    bubbleValue = -1;
                }
            } else if (bubbleValue >= 0) {
                bubbleValue = bubbleParam + (bubbleParam - eased);
            }
            if (bubbleValue < 0 && bubbleValue != -1) bubbleValue = 0;
        };
        process(s.bubbleSize, s.size, p.radiusBubble, p.radius);
        process(s.bubbleOpacity, s.opacity, p.opacityBubble, p.opacity);
    }

    void RepulseHover(Sim& sim, Particle& p, float k) {
        if (!sim.mouseIn) return;
        const Settings& s = sim.s;
        float dx = p.x - sim.mx, dy = p.y - sim.my, d = std::sqrt(dx * dx + dy * dy);
        if (d < 1e-3f) return;
        float R = s.repulseDistance;
        float factor = std::clamp((1 - (d / R) * (d / R)) * 100, 0.0f, 50.0f) * std::min(k, 2.0f);
        float nx = p.x + dx / d * factor, ny = p.y + dy / d * factor;
        if (s.outBounce) {
            if (nx - p.radius > 0 && nx + p.radius < sim.w) p.x = nx;
            if (ny - p.radius > 0 && ny + p.radius < sim.h) p.y = ny;
        } else {
            p.x = nx;
            p.y = ny;
        }
    }

    void RepulseClick(Sim& sim, Particle& p) {
        const Settings& s = sim.s;
        if (!sim.repulseClicking) {
            p.vx = p.vxi;
            p.vy = p.vyi;
            return;
        }
        float R3 = std::pow(s.repulseDistance / 6, 3.0f);
        float dx = sim.clickX - p.x, dy = sim.clickY - p.y, d = dx * dx + dy * dy;
        if (d > R3 || d < 1e-3f) return;
        float force = -R3 / d;
        float a = std::atan2(dy, dx);
        p.vx = force * std::cos(a);
        p.vy = force * std::sin(a);
        if (s.outBounce) {
            float nx = p.x + p.vx, ny = p.y + p.vy;
            if (nx + p.radius > sim.w || nx - p.radius < 0) p.vx = -p.vx;
            if (ny + p.radius > sim.h || ny - p.radius < 0) p.vy = -p.vy;
        }
    }

    // Links, attraction and collisions between nearby particles, using a grid so large
    // particle counts stay cheap.
    void Pairs(Sim& sim, float k) {
        const Settings& s = sim.s;
        auto& ps = sim.ps;
        if (ps.size() < 2) return;
        float maxR = 0;
        for (auto& p : ps) maxR = std::max(maxR, p.radius);
        float cell = std::max({s.lineDistance, s.bounce ? maxR * 2 : 0.0f, 8.0f});
        int cols = std::max(1, (int)std::ceil((sim.w + 2 * maxR) / cell) + 1);
        int rows = std::max(1, (int)std::ceil((sim.h + 2 * maxR) / cell) + 1);
        if ((size_t)cols * rows > 1 << 20) cols = rows = 1;  // absurd config: fall back to brute force
        head_.assign((size_t)cols * rows, -1);
        next_link_.assign(ps.size(), -1);
        cellOf_.resize(ps.size());
        auto cellIndex = [&](const Particle& p, int& cx, int& cy) {
            cx = std::clamp((int)((p.x + maxR) / cell), 0, cols - 1);
            cy = std::clamp((int)((p.y + maxR) / cell), 0, rows - 1);
        };
        for (int i = 0; i < (int)ps.size(); ++i) {
            int cx, cy;
            cellIndex(ps[i], cx, cy);
            cellOf_[i] = cy * cols + cx;
            next_link_[i] = head_[cellOf_[i]];
            head_[cellOf_[i]] = i;
        }
        for (int i = 0; i < (int)ps.size(); ++i) {
            int cx = cellOf_[i] % cols, cy = cellOf_[i] / cols;
            for (int oy = -1; oy <= 1; ++oy) {
                for (int ox = -1; ox <= 1; ++ox) {
                    int x = cx + ox, y = cy + oy;
                    if (x < 0 || y < 0 || x >= cols || y >= rows) continue;
                    for (int j = head_[y * cols + x]; j >= 0; j = next_link_[j]) {
                        if (j <= i) continue;
                        Particle& a = ps[i];
                        Particle& b = ps[j];
                        float dx = a.x - b.x, dy = a.y - b.y, d = std::sqrt(dx * dx + dy * dy);
                        if (s.lines && d <= s.lineDistance) {
                            float op = s.lineOpacity - d * s.lineOpacity / s.lineDistance;
                            if (op > 0)
                                sim.lines.push_back({a.x, a.y, b.x, b.y, s.lineColor.r, s.lineColor.g, s.lineColor.b, op, s.lineWidth});
                        }
                        if (s.attract && d <= s.lineDistance) {
                            float ax = dx / (s.rotateX * 1000) * k, ay = dy / (s.rotateY * 1000) * k;
                            a.vx -= ax;
                            a.vy -= ay;
                            b.vx += ax;
                            b.vy += ay;
                        }
                        if (s.bounce && d <= a.radius + b.radius) {
                            a.vx = -a.vx;
                            a.vy = -a.vy;
                            b.vx = -b.vx;
                            b.vy = -b.vy;
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- rendering

    bool CreateGpuObjects(Gpu& gpu) {
        ID3D11Device* dev = gpu.dev.Get();
        const D3D11_INPUT_ELEMENT_DESC part[] = {
            {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 1, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 2, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 3, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 32, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 4, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 48, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 5, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 64, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        };
        const D3D11_INPUT_ELEMENT_DESC line[] = {
            {"TEXCOORD", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 1, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            {"TEXCOORD", 2, DXGI_FORMAT_R32_FLOAT, 0, 32, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        };
        static_assert(sizeof(PartInst) == 80 && sizeof(LineInst) == 36, "instance layout");
        dev->CreateVertexShader(g_VSParticle, sizeof(g_VSParticle), nullptr, &vsPart_);
        dev->CreatePixelShader(g_PSParticle, sizeof(g_PSParticle), nullptr, &psPart_);
        dev->CreateVertexShader(g_VSLine, sizeof(g_VSLine), nullptr, &vsLine_);
        dev->CreatePixelShader(g_PSLine, sizeof(g_PSLine), nullptr, &psLine_);
        dev->CreatePixelShader(g_PSBackground, sizeof(g_PSBackground), nullptr, &psBg_);
        dev->CreateInputLayout(part, ARRAYSIZE(part), g_VSParticle, sizeof(g_VSParticle), &layoutPart_);
        dev->CreateInputLayout(line, ARRAYSIZE(line), g_VSLine, sizeof(g_VSLine), &layoutLine_);

        D3D11_BLEND_DESC bd{};
        auto& rt = bd.RenderTarget[0];
        rt.BlendEnable = TRUE;
        rt.SrcBlend = D3D11_BLEND_ONE;  // premultiplied alpha
        rt.DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
        rt.BlendOp = D3D11_BLEND_OP_ADD;
        rt.SrcBlendAlpha = D3D11_BLEND_ONE;
        rt.DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
        rt.BlendOpAlpha = D3D11_BLEND_OP_ADD;
        rt.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
        dev->CreateBlendState(&bd, &blend_);

        D3D11_SAMPLER_DESC sd{};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        dev->CreateSamplerState(&sd, &wrap_);

        D3D11_RASTERIZER_DESC rd{};
        rd.FillMode = D3D11_FILL_SOLID;
        rd.CullMode = D3D11_CULL_NONE;  // line quads face either way depending on direction
        rd.DepthClipEnable = TRUE;
        dev->CreateRasterizerState(&rd, &raster_);
        return vsPart_ && psPart_ && vsLine_ && psLine_ && psBg_ && layoutPart_ && layoutLine_ && blend_ && wrap_ && raster_;
    }

    static bool Upload(Gpu& gpu, ComPtr<ID3D11Buffer>& vb, UINT& capacity, const void* data, UINT count, UINT stride) {
        if (!count) return false;
        if (count > capacity) {
            capacity = std::max({count, capacity * 3 / 2, 256u});
            D3D11_BUFFER_DESC bd{};
            bd.ByteWidth = capacity * stride;
            bd.Usage = D3D11_USAGE_DYNAMIC;
            bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
            bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
            vb.Reset();
            if (FAILED(gpu.dev->CreateBuffer(&bd, nullptr, &vb))) {
                capacity = 0;
                return false;
            }
        }
        D3D11_MAPPED_SUBRESOURCE m;
        if (FAILED(gpu.ctx->Map(vb.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return false;
        memcpy(m.pData, data, (size_t)count * stride);
        gpu.ctx->Unmap(vb.Get(), 0);
        return true;
    }

    // CSS background-size / background-position, as the particles.js demo page uses them.
    void BackgroundTransform(float W, float H, float dpi, float out[4]) {
        float iw = (float)bg_->Width(), ih = (float)bg_->Height();
        auto tokens = [](const std::string& s) {
            std::vector<std::string> t;
            size_t i = 0;
            while (i < s.size()) {
                while (i < s.size() && s[i] == ' ') ++i;
                size_t j = i;
                while (j < s.size() && s[j] != ' ') ++j;
                if (j > i) t.push_back(s.substr(i, j - i));
                i = j;
            }
            return t;
        };
        auto length = [&](const std::string& t, float full) -> float {  // < 0 = auto
            if (t.empty() || t == "auto") return -1;
            float v = (float)atof(t.c_str());
            return t.back() == '%' ? full * v / 100 : v * dpi;
        };
        float dw, dh;
        if (cfg_.bgSize == "cover" || cfg_.bgSize == "contain") {
            float k = cfg_.bgSize == "cover" ? std::max(W / iw, H / ih) : std::min(W / iw, H / ih);
            dw = iw * k;
            dh = ih * k;
        } else {
            auto t = tokens(cfg_.bgSize);
            float a = length(t.size() > 0 ? t[0] : "auto", W), b = length(t.size() > 1 ? t[1] : "auto", H);
            if (a < 0 && b < 0) dw = iw * dpi, dh = ih * dpi;
            else if (b < 0) dw = a, dh = ih * a / iw;
            else if (a < 0) dh = b, dw = iw * b / ih;
            else dw = a, dh = b;
        }
        auto offset = [&](std::string t, float free) {
            if (t == "left" || t == "top") return 0.0f;
            if (t == "center") return free * 0.5f;
            if (t == "right" || t == "bottom") return free;
            float v = (float)atof(t.c_str());
            return !t.empty() && t.back() == '%' ? free * v / 100 : v * dpi;
        };
        auto t = tokens(cfg_.bgPosition);
        float ox = offset(t.size() > 0 ? t[0] : "50%", W - dw);
        float oy = offset(t.size() > 1 ? t[1] : "50%", H - dh);
        dw = std::max(dw, 1.0f);
        dh = std::max(dh, 1.0f);
        out[0] = W / dw;
        out[1] = H / dh;
        out[2] = -ox / dw;
        out[3] = -oy / dh;
    }

    void Render(Gpu& gpu, Screen& s, Sim& sim) {
        ID3D11DeviceContext* ctx = gpu.ctx.Get();
        const Settings& c = sim.s;
        const float clear[4] = {c.bgColor.r, c.bgColor.g, c.bgColor.b, 1};
        ctx->ClearRenderTargetView(s.rtv.Get(), clear);
        ctx->OMSetRenderTargets(1, s.rtv.GetAddressOf(), nullptr);
        D3D11_VIEWPORT vp{0, 0, (float)s.bw, (float)s.bh, 0, 1};
        ctx->RSSetViewports(1, &vp);
        ctx->OMSetBlendState(blend_.Get(), nullptr, 0xFFFFFFFF);
        ctx->RSSetState(raster_.Get());

        FrameConstants fc{(float)s.bw, (float)s.bh, 0, 0, 1, 1, 0, 0, {0, 0, 0, 0}};
        float dpi = sim.retinaOn ? sim.pxratio : sim.drawScale;
        if (bg_) {
            ID3D11ShaderResourceView* srv = bg_->Srv(gpu);
            BackgroundTransform((float)s.bw, (float)s.bh, dpi, &fc.uvScaleX);
            fc.extra[0] = c.bgRepeat ? 1.0f : 0.0f;
            gpu.SetConstants(fc);
            ctx->IASetInputLayout(nullptr);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(gpu.vs.Get(), nullptr, 0);
            ctx->PSSetShader(psBg_.Get(), nullptr, 0);
            ctx->PSSetConstantBuffers(0, 1, gpu.cb.GetAddressOf());
            ctx->PSSetSamplers(0, 1, c.bgRepeat ? wrap_.GetAddressOf() : gpu.sampler.GetAddressOf());
            ctx->PSSetShaderResources(0, 1, &srv);
            ctx->Draw(3, 0);
            fc.extra[0] = 0;
        }
        gpu.SetConstants(fc);
        ctx->VSSetConstantBuffers(0, 1, gpu.cb.GetAddressOf());
        ctx->PSSetConstantBuffers(0, 1, gpu.cb.GetAddressOf());
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        const float k = sim.drawScale;

        // Lines go underneath every particle, as in particles.js.
        lineInst_.clear();
        for (auto& l : sim.lines)
            lineInst_.push_back({l.x0 * k, l.y0 * k, l.x1 * k, l.y1 * k, l.r, l.g, l.b, l.a, l.width * k});
        if (Upload(gpu, lineVB_, lineCap_, lineInst_.data(), (UINT)lineInst_.size(), sizeof(LineInst))) {
            UINT stride = sizeof(LineInst), offset = 0;
            ctx->IASetInputLayout(layoutLine_.Get());
            ctx->IASetVertexBuffers(0, 1, lineVB_.GetAddressOf(), &stride, &offset);
            ctx->VSSetShader(vsLine_.Get(), nullptr, 0);
            ctx->PSSetShader(psLine_.Get(), nullptr, 0);
            ctx->DrawInstanced(4, (UINT)lineInst_.size(), 0, 0);
        }

        partInst_.clear();
        const float stroke = c.strokeWidth;
        for (auto& p : sim.ps) {
            float r = p.radiusBubble >= 0 ? p.radiusBubble : p.radius;
            float a = p.opacityBubble >= 0 ? p.opacityBubble : p.opacity;
            if (r <= 0 && stroke <= 0) continue;
            PartInst in{};
            in.cx = p.x * k;
            in.cy = p.y * k;
            in.fill[0] = p.color.r;
            in.fill[1] = p.color.g;
            in.fill[2] = p.color.b;
            in.fill[3] = std::clamp(a, 0.0f, 1.0f);
            in.stroke[0] = c.strokeColor.r;
            in.stroke[1] = c.strokeColor.g;
            in.stroke[2] = c.strokeColor.b;
            in.stroke[3] = stroke * k;
            float R = r, Rin = 0, n = 0, rot = 0, type = 0;
            switch (p.shape) {
            case Shape::Circle: break;
            case Shape::Edge: type = 1; break;
            case Shape::Triangle:  // equilateral, side 2r, apex up
                type = 2, n = 3, R = 2 * r / std::sqrt(3.0f), Rin = R * 0.5f;
                break;
            case Shape::Polygon: {  // side = 2.66r / (n/3), flat top
                n = c.sides;
                float side = r * 2.66f / (n / 3);
                type = 2, R = side / (2 * std::sin(kPi / n)), Rin = R * std::cos(kPi / n), rot = kPi / n;
                break;
            }
            case Shape::Star: {  // star polygon {n/2}, chord = 2 * 2.66r / (n/3), a tip up
                n = c.sides;
                float chord = r * 2 * 2.66f / (n / 3);
                type = 2, R = chord / (2 * std::sin(2 * kPi / n));
                Rin = std::max(R * std::cos(2 * kPi / n) / std::cos(kPi / n), R * 0.15f);
                break;
            }
            case Shape::Image:
                if (!image_) continue;
                // drawImage(img, x - r, y - r, 2r, 2r / ratio)
                in.cy = (p.y - r + r / c.imageRatio) * k;
                in.hx = r * k;
                in.hy = r / c.imageRatio * k;
                in.param[1] = 1;
                partInst_.push_back(in);
                continue;
            }
            float extent = (R + stroke * 0.5f) * k + 1.5f;
            in.hx = in.hy = extent;
            in.shape[0] = type;
            in.shape[1] = R * k;
            in.shape[2] = Rin * k;
            in.shape[3] = n;
            in.param[0] = rot;
            partInst_.push_back(in);
        }
        if (Upload(gpu, partVB_, partCap_, partInst_.data(), (UINT)partInst_.size(), sizeof(PartInst))) {
            UINT stride = sizeof(PartInst), offset = 0;
            ID3D11ShaderResourceView* srv = image_ ? image_->Srv(gpu) : nullptr;
            ctx->IASetInputLayout(layoutPart_.Get());
            ctx->IASetVertexBuffers(0, 1, partVB_.GetAddressOf(), &stride, &offset);
            ctx->VSSetShader(vsPart_.Get(), nullptr, 0);
            ctx->PSSetShader(psPart_.Get(), nullptr, 0);
            ctx->PSSetSamplers(0, 1, gpu.sampler.GetAddressOf());
            ctx->PSSetShaderResources(0, 1, &srv);
            ctx->DrawInstanced(4, (UINT)partInst_.size(), 0, 0);
        }

        ctx->OMSetBlendState(nullptr, nullptr, 0xFFFFFFFF);
        ctx->RSSetState(nullptr);
        ctx->IASetInputLayout(nullptr);
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    }

    Settings cfg_;
    std::vector<std::unique_ptr<Sim>> sims_;
    std::unique_ptr<Picture> bg_, image_;
    bool interactive_ = false, buttonDown_ = false;
    double interval_ = 1.0 / 30, next_ = 0, last_ = 0;
    std::mt19937 rng_{std::random_device{}()};
    std::uniform_real_distribution<float> dist_{0.0f, 1.0f};

    std::vector<int> head_, next_link_, cellOf_;
    std::vector<LineInst> lineInst_;
    std::vector<PartInst> partInst_;
    ComPtr<ID3D11Buffer> lineVB_, partVB_;
    UINT lineCap_ = 0, partCap_ = 0;
    ComPtr<ID3D11VertexShader> vsPart_, vsLine_;
    ComPtr<ID3D11PixelShader> psPart_, psLine_, psBg_;
    ComPtr<ID3D11InputLayout> layoutPart_, layoutLine_;
    ComPtr<ID3D11BlendState> blend_;
    ComPtr<ID3D11RasterizerState> raster_;
    ComPtr<ID3D11SamplerState> wrap_;
};

bool LoadParticleJson(const std::wstring& path, Json& root, std::wstring& err) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        err = L"Could not read file";
        return false;
    }
    std::string text;
    LARGE_INTEGER size;
    GetFileSizeEx(f, &size);
    text.resize((size_t)std::min<LONGLONG>(size.QuadPart, 1 << 20));
    DWORD read = 0;
    ReadFile(f, text.data(), (DWORD)text.size(), &read, nullptr);
    CloseHandle(f);
    text.resize(read);
    if (text.size() >= 3 && (unsigned char)text[0] == 0xEF) text.erase(0, 3);

    std::string jsonErr;
    if (!Json::Parse(text, root, jsonErr)) {
        err = Widen(jsonErr);
        return false;
    }

    // Settings-window tweaks: "particles.color.value=\"#ff0000\"" lines, each a JSON value.
    std::vector<wchar_t> buf(32767);
    DWORD n = GetPrivateProfileSectionW(OverrideSection(path).c_str(), buf.data(), (DWORD)buf.size(), ConfigPath().c_str());
    for (const wchar_t* line = buf.data(); line < buf.data() + n && *line; line += wcslen(line) + 1) {
        std::string kv = WideToUtf8(line);
        size_t eq = kv.find('=');
        if (kv[0] == ';' || eq == std::string::npos) continue;
        std::string key = kv.substr(0, eq), text = kv.substr(eq + 1), ignored;
        while (!key.empty() && key.back() == ' ') key.pop_back();
        Json value;
        if (!Json::Parse(text, value, ignored)) value = Json::Of(text);
        Json::SetPath(root, key, value);
    }
    return true;
}

std::unique_ptr<Source> CreateParticleSource(Gpu& gpu, const std::wstring& path, const Config& cfg, std::wstring& error) {
    auto s = std::make_unique<ParticleSource>();
    if (!s->Load(gpu, path, cfg, error)) return nullptr;
    return s;
}
