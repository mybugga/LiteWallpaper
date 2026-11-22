#version 300 es
precision mediump float;
precision highp int;

struct Globals
{
    highp vec2 iResolution;
    highp float iTime;
    highp float iFrame;
    highp vec4 _uvXform;
    highp vec4 _adjust;
    highp vec4 _rainbow;
    highp vec4 iDate;
};

uniform Globals G;

struct View
{
    highp vec4 _view;
};

uniform View V;

uniform highp sampler2D iChannel0;

layout(location = 0) out highp vec4 _entryPointOutput;

void main()
{
    highp vec2 _590 = vec2(gl_FragCoord.x + V._view.x, gl_FragCoord.y);
    highp vec2 _703 = _590 - (G.iResolution * 0.5);
    highp vec2 _728 = vec2(_703.x, -_703.y) * (2186.04638671875 / min(G.iResolution.x, G.iResolution.y));
    highp vec2 _729 = vec2(1012.0, 1010.0) + _728;
    highp vec2 _730 = _728;
    highp vec2 _609 = vec2(atan(_730.y, _730.x), length(_728));
    highp vec2 _749 = _729 * vec2(0.00048828125);
    highp vec2 _744 = _749;
    highp vec3 _772 = textureLod(iChannel0, _749, 0.0).xyz * (((step(0.0, _744.x) * step(_744.x, 1.0)) * step(0.0, _744.y)) * step(_744.y, 1.0));
    highp float _645 = smoothstep(781.0, 805.0, _609.y) * smoothstep(960.0, 936.0, _609.y);
    highp float _649 = G.iTime * 0.699999988079071044921875;
    highp float _783 = abs(fract(((_609.x - _649) * 0.15915493667125701904296875) + 0.5) - 0.5);
    highp float _804 = abs(fract(((_609.x - (_649 - 1.2000000476837158203125)) * 0.15915493667125701904296875) + 0.5) - 0.5);
    highp float _660 = exp((_783 * _783) * (-986.96044921875)) + (0.3499999940395355224609375 * exp((_804 * _804) * (-194.9551849365234375)));
    highp float _662 = smoothstep(0.25, 0.699999988079071044921875, dot(_772, vec3(0.300000011920928955078125, 0.550000011920928955078125, 0.1500000059604644775390625)));
    highp vec2 _825 = floor(_729 * vec2(0.111111111938953399658203125));
    highp vec2 _858 = fract(_825 * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _817 = _858 + vec2(dot(_858, _858 + vec2(45.31999969482421875)));
    highp vec2 _877 = fract((_825 + vec2(3.0)) * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _818 = _877 + vec2(dot(_877, _877 + vec2(45.31999969482421875)));
    highp vec3 _596 = clamp(vec4(((_772 + ((((_772 * vec3(1.10000002384185791015625, 0.949999988079071044921875, 0.699999988079071044921875)) * _660) * _645) * (0.25 + (1.10000002384185791015625 * _662)))) + (((((vec3(1.0, 0.85000002384185791015625, 0.550000011920928955078125) * (pow(0.5 + (0.5 * sin((G.iTime * (1.0 + (2.5 * fract(_817.x * _817.y)))) + (fract(_818.x * _818.y) * 40.0))), 30.0) * smoothstep(0.449999988079071044921875, 0.100000001490116119384765625, length(fract(_729 * vec2(0.111111111938953399658203125)) - vec2(0.5))))) * _662) * _645) * (0.25 + _660)) * 0.800000011920928955078125)) * (1.0 + ((0.07999999821186065673828125 * sin(G.iTime * 0.449999988079071044921875)) * _645)), 1.0).xyz, vec3(0.0), vec3(1.0));
    highp vec3 _578 = _596;
    highp vec2 _579 = _590;
    highp vec3 _1027;
    do
    {
        if (G._rainbow.z == 0.0)
        {
            _1027 = _596;
            break;
        }
        highp float _920 = G._rainbow.x + ((G._rainbow.y * _579.x) / G.iResolution.x);
        highp float _922 = cos(_920);
        highp float _946 = max(_578.x, max(_578.y, _578.z));
        _1027 = mix(((_596 * _922) + (cross(vec3(0.57735002040863037109375), _596) * sin(_920))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _596)) * (1.0 - _922)), ((vec3(0.5) + (cos(vec3(_920) + vec3(0.0, 2.094399929046630859375, 4.18879985809326171875)) * 0.5)) * dot(_596, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))) * 2.0, vec3(((_946 > 0.0) ? (1.0 - ((_946 - min(_578.x, min(_578.y, _578.z))) / _946)) : 1.0) * 0.64999997615814208984375));
        break;
    } while(false);
    highp vec3 _1028;
    if (G._adjust.x != 0.0)
    {
        highp float _993 = cos(G._adjust.x);
        _1028 = ((_1027 * _993) + (cross(vec3(0.57735002040863037109375), _1027) * sin(G._adjust.x))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _1027)) * (1.0 - _993));
    }
    else
    {
        _1028 = _1027;
    }
    _entryPointOutput = vec4(clamp(mix(vec3(dot(_1028, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))), _1028, vec3(G._adjust.y)) * G._adjust.z, vec3(0.0), vec3(1.0)), 1.0);
}

