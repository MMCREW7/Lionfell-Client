// Lionfell water. Drawn on water grounds and shoreline borders (Tile drawThing, items tagged
// "water" in data/lionfell/replacements.otml). Only the sprite's blue pixels become water: foam and
// land in the shoreline art keep their own colours. The waves are computed in world pixels, so
// they flow across tiles without seams and stay put while the camera moves; colours snap to a small
// palette (ordered dither) so it stays pixel art. Lighter (shallower) pixels in Tibia's art stay
// lighter, so shores keep their depth.

uniform sampler2D u_Tex0;
varying vec2 v_TexCoord;
uniform float u_Time;
uniform vec2 u_Resolution;
uniform vec4 u_Color;
uniform vec2 u_WaterOrigin; // framebuffer pixel (0, 0) in world pixels (scaled)
uniform float u_WaterScale; // framebuffer pixels per world pixel

const vec3 WATER0 = vec3(0.063, 0.173, 0.361);
const vec3 WATER1 = vec3(0.086, 0.243, 0.463);
const vec3 WATER2 = vec3(0.118, 0.329, 0.557);
const vec3 WATER3 = vec3(0.173, 0.431, 0.651);
const vec3 WATER4 = vec3(0.275, 0.557, 0.745);
const vec3 CREST = vec3(0.667, 0.839, 0.925);

float hash(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec3 palette(float level)
{
    if (level < 1.0) return WATER0;
    if (level < 2.0) return WATER1;
    if (level < 3.0) return WATER2;
    if (level < 4.0) return WATER3;
    return WATER4;
}

void main(void)
{
    vec4 c = texture2D(u_Tex0, v_TexCoord);
    if (c.a < 0.01)
        discard;

    // foam, sand, rock: not water
    if (c.b - max(c.r, c.g) < 0.10) {
        gl_FragColor = c * u_Color;
        return;
    }

    vec2 world = floor((vec2(gl_FragCoord.x, u_Resolution.y - gl_FragCoord.y) + u_WaterOrigin) / u_WaterScale);
    float t = u_Time;

    // depth from the original art: Tibia draws shallow water lighter
    float lum = dot(c.rgb, vec3(0.3, 0.5, 0.2));
    float shallow = clamp((lum - 0.18) / 0.4, 0.0, 1.0);

    // two drifting wave layers, stretched sideways (the camera looks down at an angle)
    float waves = noise(world * vec2(0.045, 0.09) + vec2(t * 0.35, t * 0.12)) * 0.6
                + noise(world * vec2(0.09, 0.17) - vec2(t * 0.22, -t * 0.16)) * 0.4;

    float dither = mod(world.x + world.y * 2.0, 4.0) * 0.25 - 0.375;
    float level = (shallow * 0.5 + waves * 0.6) * 4.6 + dither * 0.5;
    vec3 colour = palette(level);

    // crests: short bright lines where a fast layer peaks on a high wave
    float crest = noise(world * vec2(0.12, 0.34) + vec2(t * 0.6, 0.0));
    if (crest > 0.84 && waves > 0.56)
        colour = CREST;

    gl_FragColor = vec4(colour, c.a) * u_Color;
}
