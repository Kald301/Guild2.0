#ifndef INCLUDE_ALEXSCAVES_BIOMES
#define INCLUDE_ALEXSCAVES_BIOMES

// ============================================================================
// Alex's Caves biome-lighting integration (injected by the IrisCaves mod)
// ----------------------------------------------------------------------------
// Alex's Caves colors its 6 cave biomes (fog/sky/ambient) through client-side
// mixins that patch the vanilla lightmap texture and sky renderer directly.
// Complementary/Photonics recomputes lighting and cave fog itself and never
// reads that patched vanilla data, so none of it normally shows up.
//
// Biome detection has two providers:
//   - alexCavesBiomeID: a shaders.properties custom uniform built from the
//     biome's temperature/rainfall values (works with no Java at all, but two
//     different mods could in theory share a temperature/rainfall pair).
//   - acBiomeIdJava: the authoritative id fed by the IrisCaves mod straight from
//     the biome registry key. 0 when the mod/bridge isn't active.
// GetAlexsCavesBiomeID() prefers the authoritative one and falls back to the
// heuristic, so the pack works whether or not the Java bridge is present.
//
// acDeepsightIntensity is Alex's Caves' Deepsight effect strength, also fed by
// the mod (0 when inactive). It can only come from Java: Iris exposes no modded
// potion effects to shaders.
// ============================================================================

#define ALEXSCAVES_CAVE_LIGHTING // Tints cave fog and ambient light to match Alex's Caves biome colors (Abyssal Chasm, Candy Cavity, Forlorn Hollows, Magnetic Caves, Primordial Caves, Toxic Caves) [ON OFF]
#define ALEXSCAVES_CAVE_LIGHTING_STRENGTH 80 // [0 10 20 30 40 50 60 70 80 90 100]

// Candy Cavity / Primordial Caves look sunlit despite being underground, and
// Forlorn Hollows is meant to feel oppressively dark ("true darkness"-like).
// Implemented the same way Complementary's own Moon Phase Influence does it
// (lib/colors/moonPhaseInfluence.glsl): a plain brightness multiplier applied
// to sceneLighting/minLighting, each with its own dedicated slider, instead of
// hijacking the vanilla Darkness-effect uniforms.
#define ALEXSCAVES_CANDY_PRIMORDIAL_BRIGHTNESS 7.00 // [0.50 1.00 1.50 2.00 2.50 3.00 3.50 4.00 4.50 5.00 5.50 6.00 6.50 7.00 7.50 8.00 8.50 9.00 9.50 10.00]
#define ALEXSCAVES_FORLORN_DARKNESS 0.25 // [0.00 0.05 0.10 0.15 0.20 0.25 0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.00]

// How much the Deepsight effect brightens dark areas (0 = ignore Deepsight).
#define ALEXSCAVES_DEEPSIGHT_STRENGTH 1.00 // [0.00 0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00 4.00]

// Abyssal Chasm dark-depths look: hides the sky, sun/moon, clouds and the sun's light shafts (rays)
// in that biome. It does NOT touch world lighting, so the biome keeps its own (dark) illumination.
#define ALEXSCAVES_ABYSSAL_SKY_CUT // Hides the sky, sun/moon, clouds and sun rays in Abyssal Chasm for a dark-depths look [ON OFF]

#define ALEXSCAVES_DEBUG_BIOME_ID 0 // [0 1] Shows temperature/rainfall/matched biome id top-left, for troubleshooting.

uniform int alexCavesBiomeID;       // Fallback id from shaders.properties (temperature/rainfall); 0 outside Alex's Caves.
uniform int acBiomeIdJava;          // Authoritative id from the IrisCaves mod; 0 if the mod/bridge is inactive.
uniform float acDeepsightIntensity; // Alex's Caves Deepsight strength from the mod; 0 if inactive.
uniform float acBossSkyAmount;      // Luxtructosaurus / primordial boss ramp: 0 = inactive, 1 = fully active.

#define ALEXSCAVES_BOSS_SKY_STRENGTH 1.00 // [0.00 0.25 0.50 0.75 1.00 1.25 1.50 2.00] How strongly the primordial boss recolors the sky/fog.
#define ALEXSCAVES_BOSS_SKY_R 0.75 // [0.00 0.05 0.10 0.15 0.20 0.25 0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.00]
#define ALEXSCAVES_BOSS_SKY_G 0.06 // [0.00 0.05 0.10 0.15 0.20 0.25 0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.00]
#define ALEXSCAVES_BOSS_SKY_B 0.05 // [0.00 0.05 0.10 0.15 0.20 0.25 0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.00]

// While the primordial boss (Luxtructosaurus) is active, recolor the sky/fog toward an intense red.
// Applied ON TOP of the biome tint so the boss atmosphere overrides the normal cave color. A no-op
// when acBossSkyAmount is 0, so it's safe to apply unconditionally. (Alex's Caves' own color is a
// dark 0.2/0.15/0.1; brightened here to a vivid red so it reads clearly through the shader's fog.)
vec3 ApplyAlexsCavesSkyOverride(vec3 baseColor) {
    vec3 bossColor = vec3(ALEXSCAVES_BOSS_SKY_R, ALEXSCAVES_BOSS_SKY_G, ALEXSCAVES_BOSS_SKY_B);
    return mix(baseColor, bossColor, clamp(acBossSkyAmount * ALEXSCAVES_BOSS_SKY_STRENGTH, 0.0, 1.0));
}

// Prefer the mod's authoritative id; fall back to the temperature/rainfall heuristic.
int GetAlexsCavesBiomeID() {
    return acBiomeIdJava != 0 ? acBiomeIdJava : alexCavesBiomeID;
}

// Additive ambient floor contributed by the Deepsight effect (lets you see in the dark).
vec3 GetAlexsCavesDeepsightAmbient() {
    return vec3(acDeepsightIntensity * ALEXSCAVES_DEEPSIGHT_STRENGTH) * vec3(0.05, 0.06, 0.08);
}

// Brightness multiplier applied to scene/minimum lighting for the current
// Alex's Caves biome. 1.0 = unchanged, >1.0 = brighter (Candy Cavity,
// Primordial Caves), <1.0 = darker (Forlorn Hollows). ALEXSCAVES_CAVE_LIGHTING_STRENGTH
// blends how strongly this applies; the two brightness/darkness sliders above
// set the target multiplier itself.
float GetAlexsCavesLightMultiplier(int acBiome) {
    float targetMult = 1.0;
    if (acBiome == 2) targetMult = ALEXSCAVES_CANDY_PRIMORDIAL_BRIGHTNESS; // Candy Cavity
    if (acBiome == 5) targetMult = ALEXSCAVES_CANDY_PRIMORDIAL_BRIGHTNESS; // Primordial Caves
    if (acBiome == 3) targetMult = ALEXSCAVES_FORLORN_DARKNESS;            // Forlorn Hollows

    #ifdef ALEXSCAVES_CAVE_LIGHTING
        return mix(1.0, targetMult, ALEXSCAVES_CAVE_LIGHTING_STRENGTH * 0.01);
    #else
        return 1.0;
    #endif
}

// Biome fog_color from Alex's Caves' own biome json files, converted to 0-1 RGB.
vec3 GetAlexsCavesFogColor(int acBiome) {
    if (acBiome == 1) return vec3(0.000, 0.059, 0.173); // Abyssal Chasm
    if (acBiome == 2) return vec3(0.965, 0.761, 0.812); // Candy Cavity
    if (acBiome == 3) return vec3(0.125, 0.102, 0.082); // Forlorn Hollows
    if (acBiome == 4) return vec3(0.078, 0.067, 0.094); // Magnetic Caves
    if (acBiome == 5) return vec3(0.949, 0.847, 0.376); // Primordial Caves
    if (acBiome == 6) return vec3(0.522, 0.996, 0.000); // Toxic Caves
    return vec3(1.0);
}

// Biome sky_color from Alex's Caves' own biome json files, used as an ambient light tint.
vec3 GetAlexsCavesAmbientColor(int acBiome) {
    if (acBiome == 1) return vec3(0.482, 0.643, 1.000); // Abyssal Chasm
    if (acBiome == 2) return vec3(0.937, 0.514, 0.702); // Candy Cavity
    if (acBiome == 3) return vec3(0.157, 0.129, 0.102); // Forlorn Hollows
    if (acBiome == 4) return vec3(0.302, 0.263, 0.349); // Magnetic Caves
    if (acBiome == 5) return vec3(0.945, 0.788, 0.451); // Primordial Caves
    if (acBiome == 6) return vec3(0.031, 0.898, 0.004); // Toxic Caves
    return vec3(1.0);
}

// Convenience one-call helper used by the per-pack fog hooks: tints a base fog color toward the
// current Alex's Caves biome fog color, then applies the primordial boss sky/fog override on top.
// No-op outside Alex's Caves biomes and when no boss is active, so it's safe to call unconditionally.
vec3 ApplyAlexsCavesFog(vec3 baseFog) {
    #ifdef ALEXSCAVES_CAVE_LIGHTING
        int acFogBiome = GetAlexsCavesBiomeID();
        if (acFogBiome > 0) {
            baseFog = mix(baseFog, GetAlexsCavesFogColor(acFogBiome), ALEXSCAVES_CAVE_LIGHTING_STRENGTH * 0.01);
        }
    #endif
    return ApplyAlexsCavesSkyOverride(baseFog);
}

// Some packs (Photon) fade their "border fog" — the fog that hides unloaded chunks at the edge of the
// render distance — to black when underground, and skip cave fog entirely on sky pixels. In a big open
// cave that leaves ugly black patches wherever the void or the bare sky shows through. Inside Alex's
// Caves biomes (or while the primordial boss is active) blend that color toward the biome's cave fog
// instead, so the void reads as fog like it does on Complementary. Outside those cases the pack's own
// look is returned untouched.
//
// caveAmount is the pack's 0..1 "how underground am I" factor (Photon's biome_cave).
//
// Keyed off the authoritative acBiomeIdJava only: the temperature/rainfall fallback would match plain
// vanilla caves under an Ocean/River biome (both 0.5/0.5, same as Abyssal Chasm) and recolor their void.
vec3 ApplyAlexsCavesCaveVoid(vec3 borderColor, float caveAmount, vec3 caveFogBase) {
    #ifdef ALEXSCAVES_CAVE_LIGHTING
        if (acBiomeIdJava > 0 || acBossSkyAmount > 0.0) {
            return mix(borderColor, ApplyAlexsCavesFog(caveFogBase), clamp(caveAmount, 0.0, 1.0));
        }
    #endif
    return borderColor;
}

// One-call helper for packs whose diffuse/cave lighting we hook (used by the non-Complementary patch
// sets). Applies, in order: the Alex's Caves biome ambient tint weighted toward caves (strongest where
// skylight is 0), the biome brightness multiplier (Forlorn Hollows darkness, Candy Cavity / Primordial
// Caves sunlit boost) and the Deepsight ambient floor. skylightLevel is the pack's 0..1 sky light
// level. Fully a no-op outside Alex's Caves biomes with no Deepsight, so it's safe to call always.
vec3 ApplyAlexsCavesDiffuse(vec3 lighting, float skylightLevel) {
    int acBiome = GetAlexsCavesBiomeID();
    #ifdef ALEXSCAVES_CAVE_LIGHTING
        if (acBiome > 0) {
            float caveAmount = 1.0 - clamp(skylightLevel, 0.0, 1.0);
            lighting *= mix(vec3(1.0), GetAlexsCavesAmbientColor(acBiome),
                            ALEXSCAVES_CAVE_LIGHTING_STRENGTH * 0.01 * caveAmount);
        }
    #endif
    lighting *= GetAlexsCavesLightMultiplier(acBiome);
    return lighting + GetAlexsCavesDeepsightAmbient();
}

// Abyssal Chasm sky cut: returns 0.0 in Abyssal Chasm, else 1.0. Multiply sky / sun-moon / cloud /
// sunlight colors by this to seal off the sky in that biome.
//
// IMPORTANT: this uses the authoritative acBiomeIdJava ONLY, never the temperature/rainfall fallback.
// Abyssal Chasm shares its (temperature 0.5, rainfall 0.5) pair with vanilla Ocean/River, so the
// heuristic would false-positive there and kill the sky/sunlight in oceans. When the Java bridge is
// inactive acBiomeIdJava is 0, so the cut simply never triggers (safe no-op) rather than misfiring.
float GetAlexsCavesSkyCut() {
    #ifdef ALEXSCAVES_ABYSSAL_SKY_CUT
        return acBiomeIdJava == 1 ? 0.0 : 1.0;
    #else
        return 1.0;
    #endif
}

#endif
