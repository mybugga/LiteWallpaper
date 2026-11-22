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

layout(location = 0) out highp vec4 _entryPointOutput;

void main()
{
    highp vec2 _352 = vec2(gl_FragCoord.x + V._view.x, gl_FragCoord.y);
    highp vec2 _381 = ((_352 - (G.iResolution * 0.5)) / vec2(G.iResolution.y)) * 3.0;
    highp vec2 _366 = _381;
    highp vec3 _358 = clamp(vec4((vec3(0.5) + (cos(((vec3((((sin(_366.x + (G.iTime * 0.1500000059604644775390625)) + sin((_366.y * 1.2999999523162841796875) - (G.iTime * 0.16500000655651092529296875))) + sin(((_366.x + _366.y) * 0.699999988079071044921875) + (G.iTime * 0.10500000417232513427734375))) + sin(length(_381 + vec2(sin(G.iTime * 0.07500000298023223876953125), cos(G.iTime * 0.060000002384185791015625))) * 2.0)) * 0.1500000059604644775390625) + vec3(0.0, 0.3300000131130218505859375, 0.670000016689300537109375)) + vec3(G.iTime * 0.007500000298023223876953125)) * 6.283100128173828125) * 0.5)) * 0.3499999940395355224609375, 1.0).xyz, vec3(0.0), vec3(1.0));
    highp vec3 _340 = _358;
    highp vec2 _341 = _352;
    highp vec3 _579;
    do
    {
        if (G._rainbow.z == 0.0)
        {
            _579 = _358;
            break;
        }
        highp float _472 = G._rainbow.x + ((G._rainbow.y * _341.x) / G.iResolution.x);
        highp float _474 = cos(_472);
        highp float _498 = max(_340.x, max(_340.y, _340.z));
        _579 = mix(((_358 * _474) + (cross(vec3(0.57735002040863037109375), _358) * sin(_472))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _358)) * (1.0 - _474)), ((vec3(0.5) + (cos(vec3(_472) + vec3(0.0, 2.094399929046630859375, 4.18879985809326171875)) * 0.5)) * dot(_358, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))) * 2.0, vec3(((_498 > 0.0) ? (1.0 - ((_498 - min(_340.x, min(_340.y, _340.z))) / _498)) : 1.0) * 0.64999997615814208984375));
        break;
    } while(false);
    highp vec3 _580;
    if (G._adjust.x != 0.0)
    {
        highp float _545 = cos(G._adjust.x);
        _580 = ((_579 * _545) + (cross(vec3(0.57735002040863037109375), _579) * sin(G._adjust.x))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _579)) * (1.0 - _545));
    }
    else
    {
        _580 = _579;
    }
    _entryPointOutput = vec4(clamp(mix(vec3(dot(_580, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))), _580, vec3(G._adjust.y)) * G._adjust.z, vec3(0.0), vec3(1.0)), 1.0);
}

