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
uniform highp sampler2D iChannel1;

layout(location = 0) out highp vec4 _entryPointOutput;

void main()
{
    highp vec2 _672 = vec2(gl_FragCoord.x + V._view.x, gl_FragCoord.y);
    highp vec2 _804 = _672 - (G.iResolution * 0.5);
    highp vec2 _829 = vec2(_804.x, -_804.y) * (2193.023193359375 / min(G.iResolution.x, G.iResolution.y));
    highp vec2 _830 = vec2(1016.0, 1011.0) + _829;
    highp vec2 _831 = _829;
    highp vec2 _691 = vec2(atan(_831.y, _831.x), length(_829));
    highp vec2 _850 = _830 * vec2(0.00048828125);
    highp vec2 _845 = _850;
    highp vec3 _873 = textureLod(iChannel0, _850, 0.0).xyz * (((step(0.0, _845.x) * step(_845.x, 1.0)) * step(0.0, _845.y)) * step(_845.y, 1.0));
    highp float _731 = smoothstep(823.0, 831.0, _691.y) * smoothstep(921.0, 913.0, _691.y);
    highp vec3 _1215;
    if (_731 > 0.0)
    {
        highp float _739 = G.iTime * (-0.078000001609325408935546875);
        highp vec2 _698 = _829;
        highp float _879 = cos(_739);
        highp float _881 = sin(_739);
        highp vec2 _741 = vec2(1016.0, 1011.0) + vec2((_879 * _698.x) - (_881 * _698.y), (_881 * _698.x) + (_879 * _698.y));
        highp vec2 _928 = _741 * vec2(0.00048828125);
        highp vec2 _923 = _928;
        _1215 = mix(_873, textureLod(iChannel1, _830 * vec2(0.00048828125), 0.0).xyz * (((textureLod(iChannel0, _928, 0.0).xyz * (((step(0.0, _923.x) * step(_923.x, 1.0)) * step(0.0, _923.y)) * step(_923.y, 1.0))) + vec3(0.014999999664723873138427734375)) / (textureLod(iChannel1, _741 * vec2(0.00048828125), 0.0).xyz + vec3(0.014999999664723873138427734375))), vec3(_731));
    }
    else
    {
        _1215 = _873;
    }
    highp float _761 = (smoothstep(790.0, 800.0, _691.y) * (1.0 - _731)) * smoothstep(953.0, 943.0, _691.y);
    highp float _763 = dot(_1215, vec3(0.300000011920928955078125, 0.5, 0.20000000298023223876953125));
    highp float _971 = abs(fract(((_691.x - (G.iTime * 0.89999997615814208984375)) * 0.15915493667125701904296875) + 0.5) - 0.5);
    highp float _992 = abs(fract(((_691.x - ((G.iTime * (-0.60000002384185791015625)) + 2.0)) * 0.15915493667125701904296875) + 0.5) - 0.5);
    highp vec2 _1013 = floor(_830 * vec2(0.16666667163372039794921875));
    highp vec2 _1046 = fract(_1013 * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _1005 = _1046 + vec2(dot(_1046, _1046 + vec2(45.31999969482421875)));
    highp vec2 _1065 = fract((_1013 + vec2(3.0)) * vec2(123.339996337890625, 456.209991455078125));
    highp vec2 _1006 = _1065 + vec2(dot(_1065, _1065 + vec2(45.31999969482421875)));
    highp vec3 _678 = clamp(vec4((_1215 + ((((vec3(0.85000002384185791015625, 0.920000016689300537109375, 1.0) * (exp((_971 * _971) * (-2741.556884765625)) + exp((_992 * _992) * (-3947.841796875)))) * _761) * smoothstep(0.20000000298023223876953125, 0.60000002384185791015625, _763)) * 0.89999997615814208984375)) + ((((vec3(0.89999997615814208984375, 0.949999988079071044921875, 1.0) * (pow(0.5 + (0.5 * sin((G.iTime * (1.0 + (2.5 * fract(_1005.x * _1005.y)))) + (fract(_1006.x * _1006.y) * 40.0))), 36.0) * smoothstep(0.449999988079071044921875, 0.100000001490116119384765625, length(fract(_830 * vec2(0.16666667163372039794921875)) - vec2(0.5))))) * _761) * smoothstep(0.3499999940395355224609375, 0.699999988079071044921875, _763)) * 0.5), 1.0).xyz, vec3(0.0), vec3(1.0));
    highp vec3 _660 = _678;
    highp vec2 _661 = _672;
    highp vec3 _1216;
    do
    {
        if (G._rainbow.z == 0.0)
        {
            _1216 = _678;
            break;
        }
        highp float _1108 = G._rainbow.x + ((G._rainbow.y * _661.x) / G.iResolution.x);
        highp float _1110 = cos(_1108);
        highp float _1134 = max(_660.x, max(_660.y, _660.z));
        _1216 = mix(((_678 * _1110) + (cross(vec3(0.57735002040863037109375), _678) * sin(_1108))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _678)) * (1.0 - _1110)), ((vec3(0.5) + (cos(vec3(_1108) + vec3(0.0, 2.094399929046630859375, 4.18879985809326171875)) * 0.5)) * dot(_678, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))) * 2.0, vec3(((_1134 > 0.0) ? (1.0 - ((_1134 - min(_660.x, min(_660.y, _660.z))) / _1134)) : 1.0) * 0.64999997615814208984375));
        break;
    } while(false);
    highp vec3 _1217;
    if (G._adjust.x != 0.0)
    {
        highp float _1181 = cos(G._adjust.x);
        _1217 = ((_1216 * _1181) + (cross(vec3(0.57735002040863037109375), _1216) * sin(G._adjust.x))) + ((vec3(0.57735002040863037109375) * dot(vec3(0.57735002040863037109375), _1216)) * (1.0 - _1181));
    }
    else
    {
        _1217 = _1216;
    }
    _entryPointOutput = vec4(clamp(mix(vec3(dot(_1217, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))), _1217, vec3(G._adjust.y)) * G._adjust.z, vec3(0.0), vec3(1.0)), 1.0);
}

