#include <metal_stdlib>
using namespace metal;

// Живые фоны-шейдеры (просьба владельца после 1.96 по референсам: «разные формы» — неоновая жидкость, шёлк
// со светящейся каймой, световые нити, волна-лента, светящаяся сфера, переливающаяся сфера).
// Формулы один в один с прототипом на Python (scratchpad, all6.py), где подбирался вид.
// Координаты — в точках экрана: W×H, начало сверху слева.

struct BackdropUniforms {
    float4 c1;      // цвета обложки (rgb)
    float4 c2;
    float4 c3;
    float4 params;  // x — время, y — стиль, z — затемнение (dim), w — пикселей на точку
    float4 size;    // x, y — размер картинки в пикселях, w — затемнение книзу
};

struct BackdropOut {
    float4 position [[position]];
};

vertex BackdropOut backdropVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    BackdropOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

float hash2(float2 i) {
    float px = 50.0 * fract(i.x * 0.3183099 + 0.71);
    float py = 50.0 * fract(i.y * 0.3183099 + 0.113);
    return fract(px * py * (px + py));
}

float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash2(i);
    float b = hash2(i + float2(1.0, 0.0));
    float c = hash2(i + float2(0.0, 1.0));
    float d = hash2(i + float2(1.0, 1.0));
    return a + (b - a) * u.x + (c - a) * u.y + (a - b - c + d) * u.x * u.y;
}

float fbm(float2 p, int octaves) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < octaves; i++) {
        v += a * noise2(p);
        float fi = float(i);
        p = float2(p.x * 2.02 + 1.7 * fi, p.y * 2.03 + 9.2 * fi);
        p = float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y);
        a *= 0.5;
    }
    return v;
}

// Поле «перетекающего» шума (domain warping): f — форма 0…1, q и r — промежуточные поля для оттенков.
float warp(float2 p, float t, float k, float kk, float lo, float hi, thread float &q, thread float &r) {
    float qx = fbm(float2(p.x + t * 0.05, p.y), 4);
    float qy = fbm(float2(p.x + 5.2, p.y + 1.3 - t * 0.04), 4);
    float rx = fbm(float2(p.x + k * qx + 1.7 + t * 0.08, p.y + k * qy + 9.2), 4);
    float ry = fbm(float2(p.x + k * qx + 8.3, p.y + k * qy + 2.8 + t * 0.06), 4);
    float f = fbm(float2(p.x + kk * rx, p.y + kk * ry), 3);
    q = qx;
    r = rx;
    return saturate((f - lo) / (hi - lo));
}

float3 fluidStyle(float2 pt, float W, float t, float3 c1, float3 c2) {
    float q, r;
    float f = warp(pt / W * 1.1, t, 2.0, 2.2, 0.18, 0.6, q, r);
    float rim = 0.0, glow = 0.0;
    for (int i = 0; i < 3; i++) {
        float L = 0.35 + 0.2 * float(i);
        rim += pow(saturate(1.0 - abs(f - L) * 16.0), 3.0);
        glow += pow(saturate(1.0 - abs(f - L) * 6.0), 2.0);
    }
    glow *= 0.5;
    float3 col = mix(c1, c2, saturate(q));
    return col * (rim * 1.4 + glow * 0.35);
}

float3 silkStyle(float2 pt, float W, float t, float3 c1, float3 c2) {
    float q, r;
    float f = warp(pt / W * 0.75, t, 1.6, 1.6, 0.36, 0.57, q, r);
    float rim = 0.0;
    for (int i = 0; i < 2; i++) {
        float L = i == 0 ? 0.42 : 0.72;
        rim += pow(saturate(1.0 - abs(f - L) * 30.0), 2.0) * 0.9 + pow(saturate(1.0 - abs(f - L) * 7.0), 2.0) * 0.22;
    }
    float vol = pow(saturate((f - 0.35) * 1.7), 2.0) * 0.45;
    float3 gray = 0.55 * c2 + 0.45 * float3(0.6, 0.65, 0.75);
    return c1 * rim * 1.2 + gray * vol;
}

float3 fibersStyle(float2 pt, float W, float t, float3 c1, float3 c2) {
    float q, r;
    float f = warp(float2(pt.x / W * 4.4, pt.y / W * 0.66), t, 2.0, 2.2, 0.3, 0.65, q, r);
    float stri = pow(0.5 + 0.5 * sin(r * 90.0 + q * 20.0), 3.0);
    float mask = pow(saturate((f - 0.35) * 1.6), 2.0);
    float3 deep = c2 * 0.9;
    return deep * (mask * (1.1 * stri + 0.25)) + c1 * (mask * stri * 0.35);
}

float3 waveStyle(float2 pt, float W, float H, float t, float3 c2, float3 c3) {
    float px = (pt.x - W * 0.5) / H;
    float py = (pt.y - H * 0.42) / H;
    // Лента не выходит за ±0,1 высоты (+ свечение): дальше — ничего не считаем (экономия: 72 экспоненты на точку).
    if (abs(py) > 0.17) return float3(0.0);
    float env = exp(-(px / 0.4) * (px / 0.4));
    float acc = 0.0, glow = 0.0;
    const int N = 36;
    for (int i = 0; i < N; i++) {
        float ph = float(i) / float(N);
        float yc = 0.075 * sin(px * 9.0 + t * 0.35 + ph * 1.6) * (0.55 + 0.45 * sin(px * 5.3 - t * 0.2 + ph * 3.1))
                 + 0.02 * sin(ph * 6.28 + t * 0.3);
        float d = py - yc;
        acc += exp(-(d / 0.0016) * (d / 0.0016)) * env * (0.35 + 0.65 * sin(ph * 3.14));
        glow += exp(-(d / 0.02) * (d / 0.02)) * env * 0.05;
    }
    float3 col = mix(c2, c3, saturate(px * 2.0 + 0.5));
    return col * (acc * 0.9 + glow);
}

float3 orbStyle(float2 pt, float W, float H, float t, float3 c1, float3 c2, float3 c3) {
    float px = (pt.x - W * 0.5) / H;
    float py = (pt.y - H * 0.4) / H;
    const float R = 0.17;
    float d = length(float2(px, py));
    float e1 = (d - R) / 0.003, e2 = (d - R) / 0.025;
    float rim = exp(-e1 * e1) * 0.9 + exp(-e2 * e2) * 0.35 + (d > R ? exp(-(d - R) / 0.06) * 0.12 : 0.0);
    float curves = 0.0;
    if (d < R) {
        float z = sqrt(max(R * R - d * d, 0.0));
        float3 P = float3(px, py, z) / R;
        for (int j = 0; j < 6; j++) {
            float a = t * 0.25 + float(j) * 1.05;
            float b = 0.6 + float(j) * 0.5;
            float3 n = float3(cos(a) * sin(b), cos(b), sin(a) * sin(b));
            float front = (P.x * n.x + P.y * n.y + P.z * n.z) / 0.025;
            float back = (P.x * n.x + P.y * n.y - P.z * n.z) / 0.025;
            curves += exp(-front * front) + exp(-back * back) * 0.55;
        }
    }
    float neb = fbm(float2(pt.x / W * 1.2 + t * 0.02, pt.y / W * 1.2), 4);
    return c2 * rim + c3 * (curves * 0.55) + c1 * (curves * 0.15) + c2 * (saturate(neb - 0.45) * 0.25);
}

float3 prismStyle(float2 pt, float W, float H, float t, float3 c1, float3 c2) {
    float px = (pt.x - W * 0.5) / H;
    float py = (pt.y - H * 0.45) / H;
    const float R = 0.2;
    float d = length(float2(px, py));
    if (d >= R) {
        return c2 * (exp(-(d - R) / 0.035) * 0.3);
    }
    float z = sqrt(max(R * R - d * d, 0.0));
    float X = px / R, Y = py / R, Z = z / R;
    float q, r;
    float f = warp(float2(X * 1.2 + 3.0, Y * 1.2 + t * 0.02), t, 2.0, 2.2, 0.2, 0.6, q, r);
    float3 film = 0.5 + 0.5 * cos(6.283 * ((f * 1.6 + q * 0.6) + float3(0.0, 0.33, 0.67)));
    film = film * 0.55 + 0.45 * float3(0.85, 0.9, 1.0);
    float3 base = (film * 0.8 + c2 * 0.2) * saturate(0.35 + f);
    float light = saturate(-X * 0.4 - Y * 0.6 + Z * 0.7);
    float spec = pow(saturate(-X * 0.35 - Y * 0.6 + Z * 0.72), 24.0);
    float fres = pow(1.0 - Z, 2.5);
    return base * (0.25 + 0.75 * light) + spec * 0.8 + c1 * (fres * 0.6);
}

fragment float4 backdropFragment(BackdropOut in [[stage_in]], constant BackdropUniforms &u [[buffer(0)]]) {
    float scale = max(u.params.w, 0.1);
    float2 pt = in.position.xy / scale;
    float W = u.size.x / scale;
    float H = u.size.y / scale;
    float t = u.params.x;
    int style = int(u.params.y + 0.5);
    float3 c1 = u.c1.rgb, c2 = u.c2.rgb, c3 = u.c3.rgb;
    float3 col;
    switch (style) {
        case 0: col = fluidStyle(pt, W, t, c1, c2); break;
        case 1: col = silkStyle(pt, W, t, c1, c2); break;
        case 2: col = fibersStyle(pt, W, t, c1, c2); break;
        case 3: col = waveStyle(pt, W, H, t, c2, c3); break;
        case 4: col = orbStyle(pt, W, H, t, c1, c2, c3); break;
        default: col = prismStyle(pt, W, H, t, c1, c2); break;
    }
    // Книзу темнее — текст и кнопки читаются; затем общее затемнение (под лентами) и мягкая гамма, как в прототипе.
    float v = pt.y / H;
    float shade = 1.0 - u.size.w * saturate((v - 0.45) / 0.55);
    col = col * shade + float3(0.008, 0.01, 0.025);
    col *= (1.0 - u.params.z);
    col = pow(saturate(col), float3(1.0 / 1.15));
    return float4(col, 1.0);
}
