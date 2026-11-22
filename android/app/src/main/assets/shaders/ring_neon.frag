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
    highp vec2 _639 = vec2(gl_FragCoord.x + V._view.x, gl_FragCoord.y);
    highp vec2 _774 = _639 - (G.iResolution * 0.5);
    highp vec2 _799 = vec2(_774.x, -_774.y) * (2204.651123046875 / min(G.iResolution.x, G.iResolution.y));
    highp vec2 _801 = _799;
    highp vec2 _658 = vec2(atan(_801.y, _801.x), length(_799));
    highp float _691 = G.iTime * (-0.20999999344348907470703125);
    highp vec2 _663 = _799;
    highp float _820 = cos(_691);
    highp float _822 = sin(_691);
    highp vec2 _847 = (vec2(1017.0, 1012.0) + vec2((_820 * _663.x) - (_822 * _663.y), (_822 * _663.x) + (_820 * _663.y))) * vec2(0.00048828125);
    highp vec2 _842 = _847;
    highp vec3 _870 = textureLod(iChannel0, _847, 0.0).xyz * (((step(0.0, _842.x) * step(_842.x, 1.0)) * step(0.0, _842.y)) * step(_842.y, 1.0));
    highp float _881 = abs(fract(((_658.x - (G.iTime * 1.0499999523162841796875)) * 0.15915493667125701904296875) + 0.5) - 0.5);
    highp float _902 = abs(fract(((_658.x - ((G.iTime * 1.0499999523162841796875) + 3.141590118408203125)) * 0.15915493667125701904296875) + 0.5) - 0.5);
    highp vec2 _723 = vec2(_658.y * 0.454545438289642333984375, _658.x * 2.0);
    highp vec2 _922 = floor(_723);
    highp vec2 _924 = fract(_723);
    highp vec2 _914 = (_924 * _924) * (vec2(3.0) - (_924 * 2.0));
    highp vec2 _958 = fract(_922 * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _915 = _958 + vec2(dot(_958, _958 + vec2(45.31999969482421875)));
    highp vec2 _977 = fract((_922 + vec2(1.0, 0.0)) * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _916 = _977 + vec2(dot(_977, _977 + vec2(45.31999969482421875)));
    highp vec2 _996 = fract((_922 + vec2(0.0, 1.0)) * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _917 = _996 + vec2(dot(_996, _996 + vec2(45.31999969482421875)));
    highp vec2 _1015 = fract((_922 + vec2(1.0)) * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _918 = _1015 + vec2(dot(_1015, _1015 + vec2(45.31999969482421875)));
    highp vec3 _741 = _870 + ((((((_870 * 1.60000002384185791015625) + vec3(0.119999997317790985107421875)) * (exp((_881 * _881) * (-1542.125732421875)) + (0.449999988079071044921875 * exp((_902 * _902) * (-815.66986083984375))))) * (smoothstep(786.0, 822.0, _658.y) * smoothstep(978.0, 942.0, _658.y))) * (0.64999997615814208984375 + (0.3499999940395355224609375 * mix(mix(fract(_915.x * _915.y), fract(_916.x * _916.y), _914.x), mix(fract(_917.x * _917.y), fract(_918.x * _918.y), _914.x), _914.y)))) * smoothstep(0.0500000007450580596923828125, 0.4000000059604644775390625, dot(_870, vec3(0.300000011920928955078125, 0.5, 0.20000000298023223876953125))));
    highp vec3 _662 = _741;
    highp float _743 = _662.x;
    highp float _745 = _662.y;
    highp float _747 = _662.z;
    highp float _751 = _662.x;
    highp float _753 = _662.y;
    highp float _755 = _662.z;
    highp vec3 _768 = _741 * (1.0 + ((0.119999997317790985107421875 * sin(G.iTime * 0.800000011920928955078125)) * smoothstep(0.100000001490116119384765625, 0.5, max(_743, max(_745, _747)) - min(_751, min(_753, _755)))));
    _662 = _768;
    highp vec3 _645 = clamp(vec4(_768, 1.0).xyz, vec3(0.0), vec3(1.0));
    highp vec3 _627 = _645;
    highp vec2 _628 = _639;
    highp vec3 _1165;
    do
    {
        if (G._rainbow.z == 0.0)
        {
            _1165 = _645;
            break;
        }
        highp float _1058 = G._rainbow.x + ((G._rainbow.y * _628.x) / G.iResolution.x);
        highp float _1060 = cos(_1058);
        highp float _1084 = max(_627.x, max(_627.y, _627.z));
        _1165 = mix(((_645 * _1060) + (cross(vec3(0.57735002040863037109375), _645) * sin(_1058))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _645)) * (1.0 - _1060)), ((vec3(0.5) + (cos(vec3(_1058) + vec3(0.0, 2.094399929046630859375, 4.18879985809326171875)) * 0.5)) * dot(_645, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))) * 2.0, vec3(((_1084 > 0.0) ? (1.0 - ((_1084 - min(_627.x, min(_627.y, _627.z))) / _1084)) : 1.0) * 0.64999997615814208984375));
        break;
    } while(false);
    highp vec3 _1166;
    if (G._adjust.x != 0.0)
    {
        highp float _1131 = cos(G._adjust.x);
        _1166 = ((_1165 * _1131) + (cross(vec3(0.57735002040863037109375), _1165) * sin(G._adjust.x))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _1165)) * (1.0 - _1131));
    }
    else
    {
        _1166 = _1165;
    }
    _entryPointOutput = vec4(clamp(mix(vec3(dot(_1166, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))), _1166, vec3(G._adjust.y)) * G._adjust.z, vec3(0.0), vec3(1.0)), 1.0);
}

