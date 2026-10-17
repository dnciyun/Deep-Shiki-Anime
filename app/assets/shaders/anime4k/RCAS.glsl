// =============================================================================
// Shader: RCAS (Standalone sharpening pass)
//
// Extracted from the "AMD FidelityFX Super Resolution v1.0.2 for mpv" GLSL port
// by agyild (RCAS block only). Unlike the FSR shader this pass does NOT upscale:
// it hooks LUMA at the source size and sharpens it there, so it takes effect at
// any playback size (windowed, 1:1, fullscreen) instead of only when upscaling.
//
// WHY: ACNet/ARNet/FSR are upscalers and mpv's `//!WHEN` guards make them skip
// when the picture is not actually being magnified (e.g. 1080p video in a
// 1080p-or-smaller player window) - users see "no effect". This pass is always on.
//
// CREDITS / LICENSE:
//  - FidelityFX FSR / RCAS (MIT) - Copyright (c) 2021 Advanced Micro Devices, Inc.
//  - mpv GLSL port by agyild (MIT)
//  - RCAS extraction by DSAnima (MIT)
// =============================================================================

//!HOOK LUMA
//!BIND HOOKED
//!DESC FidelityFX Super Resolution v1.0.2 (RCAS)
//!COMPONENTS 1

// User variables - RCAS
#define SHARPNESS 0.2 // Controls the amount of sharpening. The scale is {0.0 := maximum, to N>0, where N is the number of stops (halving) of the reduction of sharpness}. 0.0 to 2.0.
#define FSR_RCAS_DENOISE 1 // If set to 1, lessens the sharpening on noisy areas. Can be disabled for better performance. 0 or 1.
#define FSR_PQ 0 // Whether the source content has PQ gamma or not. Needs to be set to the same value for both passes. 0 or 1.

// Shader code

#define FSR_RCAS_LIMIT (0.25 - (1.0 / 16.0)) // This is set at the limit of providing unnatural results for sharpening.

float APrxMedRcpF1(float a) {
	float b = uintBitsToFloat(uint(0x7ef19fff) - floatBitsToUint(a));
	return b * (-b * a + 2.0);
}

float AMax3F1(float x, float y, float z) {
	return max(x, max(y, z)); 
}

float AMin3F1(float x, float y, float z) {
	return min(x, min(y, z));
}

#if (FSR_PQ == 1)

float FromGamma2(float a) { 
	return sqrt(sqrt(a));
}

#endif

vec4 hook() {
	// Algorithm uses minimal 3x3 pixel neighborhood.
	//    b 
	//  d e f
	//    h
#if (defined(HOOKED_gather) && (__VERSION__ >= 400 || (GL_ES && __VERSION__ >= 310)))
	vec3 bde = HOOKED_gather(HOOKED_pos + HOOKED_pt * vec2(-0.5), 0).xyz;
	float b = bde.z;
	float d = bde.x;
	float e = bde.y;

	vec2 fh = HOOKED_gather(HOOKED_pos + HOOKED_pt * vec2(0.5), 0).zx;
	float f = fh.x;
	float h = fh.y;
#else
	float b = HOOKED_texOff(vec2( 0.0, -1.0)).r;
	float d = HOOKED_texOff(vec2(-1.0,  0.0)).r;
	float e = HOOKED_tex(HOOKED_pos).r;
	float f = HOOKED_texOff(vec2(1.0, 0.0)).r;
	float h = HOOKED_texOff(vec2(0.0, 1.0)).r;
#endif

	// Min and max of ring.
	float mn1L = min(AMin3F1(b, d, f), h);
	float mx1L = max(AMax3F1(b, d, f), h);

	// Immediate constants for peak range.
	vec2 peakC = vec2(1.0, -1.0 * 4.0);

	// Limiters, these need to be high precision RCPs.
	float hitMinL = min(mn1L, e) / (4.0 * mx1L);
	float hitMaxL = (peakC.x - max(mx1L, e)) / (4.0 * mn1L + peakC.y);
	float lobeL = max(-hitMinL, hitMaxL);
	float lobe = max(float(-FSR_RCAS_LIMIT), min(lobeL, 0.0)) * exp2(-clamp(float(SHARPNESS), 0.0, 2.0));

	// Apply noise removal.
#if (FSR_RCAS_DENOISE == 1)
	// Noise detection.
	float nz = 0.25 * b + 0.25 * d + 0.25 * f + 0.25 * h - e;
	nz = clamp(abs(nz) * APrxMedRcpF1(AMax3F1(AMax3F1(b, d, e), f, h) - AMin3F1(AMin3F1(b, d, e), f, h)), 0.0, 1.0);
	nz = -0.5 * nz + 1.0;
	lobe *= nz;
#endif

	// Resolve, which needs the medium precision rcp approximation to avoid visible tonality changes.
	float rcpL = APrxMedRcpF1(4.0 * lobe + 1.0);
	vec4 pix = vec4(0.0, 0.0, 0.0, 1.0);
	pix.r = float((lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL);
#if (FSR_PQ == 1)
	pix.r = FromGamma2(pix.r);
#endif

	return pix;
}
