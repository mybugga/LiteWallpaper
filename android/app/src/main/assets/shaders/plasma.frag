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
    highp vec2 _268 = ((vec2(gl_FragCoord.x + V._view.x, gl_FragCoord.y) - (G.iResolution * 0.5)) / vec2(G.iResolution.y)) * 3.0;
    highp vec2 _253 = _268;
    highp vec3 _247 = clamp(vec4((vec3(0.5) + (cos(((vec3((((sin(_253.x + (G.iTime * 0.1500000059604644775390625)) + sin((_253.y * 1.2999999523162841796875) - (G.iTime * 0.16500000655651092529296875))) + sin(((_253.x + _253.y) * 0.699999988079071044921875) + (G.iTime * 0.10500000417232513427734375))) + sin(length(_268 + vec2(sin(G.iTime * 0.07500000298023223876953125), cos(G.iTime * 0.060000002384185791015625))) * 2.0)) * 0.1500000059604644775390625) + vec3(0.0, 0.3300000131130218505859375, 0.670000016689300537109375)) + vec3(G.iTime * 0.007500000298023223876953125)) * 6.283100128173828125) * 0.5)) * 0.3499999940395355224609375, 1.0).xyz, vec3(0.0), vec3(1.0));
    highp vec3 _375;
    if (G._adjust.x != 0.0)
    {
        highp float _341 = cos(G._adjust.x);
        _375 = ((_247 * _341) + (cross(vec3(0.57735002040863037109375), _247) * sin(G._adjust.x))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _247)) * (1.0 - _341));
    }
    else
    {
        _375 = _247;
    }
    _entryPointOutput = vec4(clamp(mix(vec3(dot(_375, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))), _375, vec3(G._adjust.y)) * G._adjust.z, vec3(0.0), vec3(1.0)), 1.0);
}

