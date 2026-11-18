#pragma once
// Minimal JSON reader, enough for particles.js config files. Tolerates // and /* */ comments.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

struct Json {
    enum Type { Null, Bool, Number, String, Array, Object } type = Null;
    bool boolean = false;
    double number = 0;
    std::string str;
    std::vector<Json> arr;
    std::vector<std::pair<std::string, Json>> obj;

    static const Json& Missing() {
        static const Json m;
        return m;
    }
    const Json& operator[](const char* key) const {
        if (type == Object)
            for (auto& kv : obj)
                if (kv.first == key) return kv.second;
        return Missing();
    }
    bool Has(const char* key) const { return &(*this)[key] != &Missing(); }
    double Num(double def) const { return type == Number ? number : type == Bool ? (boolean ? 1 : 0) : def; }
    bool Flag(bool def) const { return type == Bool ? boolean : type == Number ? number != 0 : def; }
    std::string Str(const std::string& def) const { return type == String ? str : def; }

    // Child by key, created (and this turned into an object) if needed.
    Json& Child(const std::string& key) {
        if (type != Object) {
            *this = Json();
            type = Object;
        }
        for (auto& kv : obj)
            if (kv.first == key) return kv.second;
        obj.emplace_back(key, Json());
        return obj.back().second;
    }

    // "a.b.c" lookups, as used for settings overrides.
    static const Json& AtPath(const Json& root, const std::string& path) {
        const Json* j = &root;
        size_t pos = 0;
        while (pos <= path.size()) {
            size_t dot = path.find('.', pos);
            if (dot == std::string::npos) dot = path.size();
            j = &(*j)[path.substr(pos, dot - pos).c_str()];
            if (j == &Missing()) return Missing();
            pos = dot + 1;
        }
        return *j;
    }

    static void SetPath(Json& root, const std::string& path, const Json& value) {
        Json* j = &root;
        size_t pos = 0;
        while (pos <= path.size()) {
            size_t dot = path.find('.', pos);
            if (dot == std::string::npos) dot = path.size();
            j = &j->Child(path.substr(pos, dot - pos));
            pos = dot + 1;
        }
        *j = value;
    }

    static Json Of(double v) {
        Json j;
        j.type = Number;
        j.number = v;
        return j;
    }
    static Json Of(bool v) {
        Json j;
        j.type = Bool;
        j.boolean = v;
        return j;
    }
    static Json Of(const std::string& v) {
        Json j;
        j.type = String;
        j.str = v;
        return j;
    }

    std::string Dump() const {
        switch (type) {
        case Null: return "null";
        case Bool: return boolean ? "true" : "false";
        case Number: {
            char buf[32];
            if (number == (double)(long long)number) snprintf(buf, sizeof(buf), "%lld", (long long)number);
            else snprintf(buf, sizeof(buf), "%.4g", number);
            return buf;
        }
        case String: {
            std::string out = "\"";
            for (char c : str) {
                if (c == '"' || c == '\\') out += '\\', out += c;
                else if ((unsigned char)c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else out += c;
            }
            return out + "\"";
        }
        case Array: {
            std::string out = "[";
            for (size_t i = 0; i < arr.size(); ++i) out += (i ? "," : "") + arr[i].Dump();
            return out + "]";
        }
        case Object: {
            std::string out = "{";
            for (size_t i = 0; i < obj.size(); ++i) out += (i ? "," : "") + Of(obj[i].first).Dump() + ":" + obj[i].second.Dump();
            return out + "}";
        }
        }
        return "null";
    }

    static bool Parse(const std::string& text, Json& out, std::string& error) {
        Parser p{text.data(), text.data() + text.size()};
        if (!p.Value(out) || (p.Skip(), p.s != p.e)) {
            error = "Invalid JSON near byte " + std::to_string(p.s - text.data());
            return false;
        }
        return true;
    }

private:
    struct Parser {
        const char* s;
        const char* e;

        void Skip() {
            for (;;) {
                while (s < e && (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')) ++s;
                if (s + 1 < e && s[0] == '/' && s[1] == '/') {
                    while (s < e && *s != '\n') ++s;
                } else if (s + 1 < e && s[0] == '/' && s[1] == '*') {
                    s += 2;
                    while (s + 1 < e && !(s[0] == '*' && s[1] == '/')) ++s;
                    s = s + 2 <= e ? s + 2 : e;
                } else {
                    return;
                }
            }
        }

        bool Literal(const char* word) {
            size_t n = strlen(word);
            if ((size_t)(e - s) < n || strncmp(s, word, n) != 0) return false;
            s += n;
            return true;
        }

        static void AppendUtf8(std::string& out, unsigned cp) {
            if (cp < 0x80) {
                out += (char)cp;
            } else if (cp < 0x800) {
                out += (char)(0xC0 | (cp >> 6));
                out += (char)(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                out += (char)(0xE0 | (cp >> 12));
                out += (char)(0x80 | ((cp >> 6) & 0x3F));
                out += (char)(0x80 | (cp & 0x3F));
            } else {
                out += (char)(0xF0 | (cp >> 18));
                out += (char)(0x80 | ((cp >> 12) & 0x3F));
                out += (char)(0x80 | ((cp >> 6) & 0x3F));
                out += (char)(0x80 | (cp & 0x3F));
            }
        }

        bool StringBody(std::string& out) {
            ++s;  // opening quote
            while (s < e && *s != '"') {
                if (*s != '\\') {
                    out += *s++;
                    continue;
                }
                if (++s >= e) return false;
                char c = *s++;
                switch (c) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case 'r': out += '\r'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'u': {
                    if (e - s < 4) return false;
                    unsigned cp = (unsigned)strtoul(std::string(s, 4).c_str(), nullptr, 16);
                    s += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && e - s >= 6 && s[0] == '\\' && s[1] == 'u') {
                        unsigned lo = (unsigned)strtoul(std::string(s + 2, 4).c_str(), nullptr, 16);
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        s += 6;
                    }
                    AppendUtf8(out, cp);
                    break;
                }
                default: out += c; break;
                }
            }
            if (s >= e) return false;
            ++s;  // closing quote
            return true;
        }

        bool Value(Json& v) {
            Skip();
            if (s >= e) return false;
            if (*s == '{') {
                v.type = Object;
                ++s;
                Skip();
                if (s < e && *s == '}') return ++s, true;
                for (;;) {
                    Skip();
                    if (s >= e || *s != '"') return false;
                    std::string key;
                    if (!StringBody(key)) return false;
                    Skip();
                    if (s >= e || *s++ != ':') return false;
                    v.obj.emplace_back(std::move(key), Json());
                    if (!Value(v.obj.back().second)) return false;
                    Skip();
                    if (s < e && *s == ',') { ++s; continue; }
                    if (s < e && *s == '}') return ++s, true;
                    return false;
                }
            }
            if (*s == '[') {
                v.type = Array;
                ++s;
                Skip();
                if (s < e && *s == ']') return ++s, true;
                for (;;) {
                    v.arr.emplace_back();
                    if (!Value(v.arr.back())) return false;
                    Skip();
                    if (s < e && *s == ',') { ++s; continue; }
                    if (s < e && *s == ']') return ++s, true;
                    return false;
                }
            }
            if (*s == '"') {
                v.type = String;
                return StringBody(v.str);
            }
            if (Literal("true")) { v.type = Bool; v.boolean = true; return true; }
            if (Literal("false")) { v.type = Bool; v.boolean = false; return true; }
            if (Literal("null")) { v.type = Null; return true; }
            std::string digits(s, std::min<size_t>(e - s, 64));
            char* end = nullptr;
            v.number = strtod(digits.c_str(), &end);
            size_t used = (size_t)(end - digits.c_str());
            if (!used) return false;
            v.type = Number;
            s += used;
            return true;
        }
    };
};
