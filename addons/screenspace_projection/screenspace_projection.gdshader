shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, depth_test_disabled;

uniform sampler2D screen_tex : filter_linear, repeat_disable;

/* Master switch. Off = passthrough. */
uniform bool enabled = true;

/* Projection model.
   Rectilinear: preserves straight lines.
   Panini: preserves vertical straight lines and lines passing through center.
   Equirectangular (lat-long): uniform latitude / longitude sampling.
   Fisheye Stereographic: preserves angles (conformal).
   Fisheye Equisolid: preserves solid angle (equal area on the sphere).
*/
uniform int projection_mode : hint_enum(
	"Rectilinear:0",
	"Panini:1",
	"Equirectangular (lat-long):2",
	"Fisheye Stereographic:3",
	"Fisheye Equisolid:4"
) = 1;

/* Strength.
   Panini: D (0..1). Others: blend (0 = rectilinear, 1 = full). */
uniform float strength : hint_range(0.0, 1.0) = 0.5;

/* Fill (auto-zoom) to remove empty corners.
   0 = none, 1 = minimal crop that keeps corners valid. */
uniform float fill : hint_range(0.0, 1.0) = 1.0;

/* Panini vertical compensation for very wide angles. */
uniform float panini_s : hint_range(-1.0, 1.0) = 0.0;

group_uniforms ProjectionSampling;

/* Anisotropic filter radius caps (quality vs cost). */
uniform int max_major_radius : hint_range(1, 9, 1) = 5;
uniform int max_minor_radius : hint_range(0, 6, 1) = 3;

group_uniforms FOV;

/* Interpret fov_deg as vertical FOV (recommended for Camera3D). */
uniform bool fov_is_vertical = true;

/* Camera FOV in degrees used to reconstruct the source perspective. */
uniform float fov_deg : hint_range(1.0, 179.0) = 150.0;

group_uniforms Chromatic_Aberration;

/* Lateral chromatic aberration amount (0 = none). */
uniform float ca_amount : hint_range(0.0, 1.0) = 0.0;

/* Where CA grows (lower = near edges only, higher = broader). */
uniform float ca_amount_spread : hint_range(0.01, 1.0) = 0.5;

/* Spectral integration wavelength band (nm). */
const float CA_MIN_WAVELENGTH = 360.0;
const float CA_MAX_WAVELENGTH = 730.0;

/* Reference wavelength (nm) used as the "no shift" anchor for dispersion. */
uniform float ca_reference_wavelength: hint_range(360.0, 730.0) = 540.0;

/* CA pixel activation threshold (bypasses CA algorithm where it produces little to no change). */
uniform float ca_enable_start : hint_range(0.0, 5.0) = 0.5;

/* Time-based spectral tap jitter to reduce banding in CA. */
uniform bool ca_jitter = true;

uniform int ca_max_samples: hint_range(8, 64) = 16;

uniform float ca_samples_per_ca : hint_range(0.0, 8.0) = 0.5;

// BK7 constants
const vec3 B = vec3(1.03961212, 0.231792344, 1.01046945);
const vec3 C = vec3(0.00600069867, 0.0200179144, 103.560653);

group_uniforms Vignette;

/* Vignette strength (0 = none). */
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.0;

/* Vignette falloff (lower = edge-only, higher = wider). */
uniform float vignette_spread : hint_range(0.0, 1.0) = 0.5;

const float EPS = 1e-8;
const float OOB_SENTINEL = 1e9;

const vec2 CORNERS[4] = vec2[4](
	vec2(-1.0, -1.0),
	vec2( 1.0, -1.0),
	vec2(-1.0,  1.0),
	vec2( 1.0,  1.0)
);

float gain_from_unit(float x) {
	return 1.0 / (1.0 - min(x, 0.9999)) - 1.0;
}

bool in_01(vec2 uv) {
	return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

vec3 ray_rectilinear(vec2 projected_xy) {
	return normalize(vec3(projected_xy, 1.0));
}

vec2 panini_forward(vec2 latlon, float d) {
	float denom = d + cos(latlon.y);
	float k = (d + 1.0) / denom;
	return vec2(k * sin(latlon.y), k * tan(latlon.x));
}

vec3 panini_inverse_s(vec2 projected_xy, float d, float s) {
	float dp1 = d + 1.0;
	float k = (projected_xy.x * projected_xy.x) / (dp1 * dp1);

	float disc = k * k * d * d - (k + 1.0) * (k * d * d - 1.0);
	if (disc <= 0.0) return ray_rectilinear(projected_xy);

	float c_lon = (-k * d + sqrt(disc)) / (k + 1.0);
	float S = dp1 / (d + c_lon);

	vec2 ang = vec2(atan(projected_xy.y, S), atan(projected_xy.x, S * c_lon)); // (lat, lon)

	float cos_lat = cos(ang.x);
	vec3 ray = vec3(cos_lat * sin(ang.y), sin(ang.x), cos_lat * cos(ang.y));

	if (ray.z > 0.0) {
		float q = ray.x / ray.z;
		q = (q * q) / ((d + 1.0) * (d + 1.0));
		ray.y *= mix(1.0, 1.0 / sqrt(1.0 + q), s);
	}
	return ray;
}

vec3 ray_from_lat_lon(vec2 latlon) {
	float cos_lat = cos(latlon.x);
	return vec3(cos_lat * sin(latlon.y), sin(latlon.x), cos_lat * cos(latlon.y));
}

vec3 ray_equirectangular(vec2 screen_xy, vec2 max_rect_xy) {
	vec2 max_latlon = atan(max_rect_xy.yx);
	return ray_from_lat_lon(screen_xy.yx * max_latlon);
}

vec3 ray_fisheye(vec2 screen_xy, vec2 max_rect_xy, float aspect, bool stereographic) {
	vec2 p = vec2(screen_xy.x * aspect, screen_xy.y);
	float r = length(p);
	if (r < EPS) return vec3(0.0, 0.0, 1.0);

	float theta_max = min(atan(max_rect_xy.x), atan(max_rect_xy.y));
	float theta = stereographic
		? 2.0 * atan(r * tan(0.5 * theta_max))
		: 2.0 * asin(clamp(r * sin(0.5 * theta_max), 0.0, 1.0));

	return normalize(vec3((p / r) * sin(theta), cos(theta)));
}

vec3 uv_blend_ray(vec3 rect_ray, vec3 proj_ray, float b) {
	vec2 uv_r = rect_ray.xy / max(rect_ray.z, EPS);
	vec2 uv_p = proj_ray.xy / max(proj_ray.z, EPS);
	return vec3(mix(uv_r, uv_p, b), 1.0);
}

vec3 projected_ray_for_mode(
	int mode,
	vec2 screen_xy,
	vec2 projected_xy,
	vec2 max_rect_xy,
	float aspect,
	float d,
	float panini_s_param
) {
	if (mode == 1) return panini_inverse_s(projected_xy, d, panini_s_param);
	if (mode == 2) return ray_equirectangular(screen_xy, max_rect_xy);
	if (mode == 3) return ray_fisheye(screen_xy, max_rect_xy, aspect, true);
	if (mode == 4) return ray_fisheye(screen_xy, max_rect_xy, aspect, false);
	return ray_rectilinear(projected_xy);
}

vec3 final_view_ray_for_screen_pos(
	vec2 screen_xy,
	int mode,
	vec2 max_rect_xy,
	float blend_strength,
	float d,
	float panini_s_param,
	float aspect
) {
	vec2 projected_xy = screen_xy * max_rect_xy;
	vec3 rect = ray_rectilinear(projected_xy);
	vec3 proj = projected_ray_for_mode(mode, screen_xy, projected_xy, max_rect_xy, aspect, d, panini_s_param);

	// Equirectangular blends in UV space because it looks better
	if (mode == 2) return uv_blend_ray(rect, proj, blend_strength);
	if (mode == 1) return proj;

	return mix(rect, proj, blend_strength);
}

vec4 sample_anisotropic(
	sampler2D tex,
	vec2 source_uv,
	vec2 texel_uv,
	vec2 dsource_dx_uv,
	vec2 dsource_dy_uv
) {
	#define IN01(U) (all(greaterThanEqual((U), vec2(0.0))) && all(lessThanEqual((U), vec2(1.0))))
	#define ACCUM(NEED_CHECK, UV, W) \
		if (!(NEED_CHECK) || IN01(UV)) { \
			sum  += textureGrad(tex, (UV), dsource_dx_uv, dsource_dy_uv) * (W); \
			wsum += (W); \
		}

	vec2 inv_texel_uv = 1.0 / max(texel_uv, vec2(EPS));
	vec2 fp_dx_tex = dsource_dx_uv * inv_texel_uv;
	vec2 fp_dy_tex = dsource_dy_uv * inv_texel_uv;

	vec2 fp_len = vec2(length(fp_dx_tex), length(fp_dy_tex));
	float major_len = max(fp_len.x, fp_len.y);
	float minor_len = min(fp_len.x, fp_len.y);

	if (major_len <= 1.0)
		return textureGrad(tex, clamp(source_uv, vec2(0.0), vec2(1.0)), dsource_dx_uv, dsource_dy_uv);

	bool dx_major = (fp_len.x >= fp_len.y);
	vec2 major_axis_tex = dx_major ? fp_dx_tex : fp_dy_tex;
	vec2 minor_axis_tex = dx_major ? fp_dy_tex : fp_dx_tex;

	vec2 major_step_uv = normalize(major_axis_tex) * texel_uv;
	vec2 minor_step_uv = normalize(minor_axis_tex) * texel_uv;

	vec2 len_pm = vec2(major_len, minor_len);
	ivec2 r = ivec2(
		clamp(int(ceil(len_pm.x - 1.0)), 1, clamp(max_major_radius, 1, 9)),
		clamp(int(ceil(len_pm.y - 1.0)), 0, clamp(max_minor_radius, 0, 6))
	);
	int major_radius = r.x;
	int minor_radius = r.y;

	vec2 sigma = max((len_pm - 1.0) * 0.85, vec2(0.35));
	float inv_2sig2_major = 0.5 / max(sigma.x * sigma.x, EPS);
	float inv_sig_minor   = 1.0 / max(sigma.y, EPS);

	vec2 kernel_extent = abs(major_step_uv) * float(major_radius) + abs(minor_step_uv) * float(minor_radius);
	bool need_check = !(all(greaterThanEqual(source_uv - kernel_extent, vec2(0.0)))
	                 && all(lessThanEqual(source_uv + kernel_extent, vec2(1.0))));

	vec4 minor_sum = vec4(0.0);
	float minor_wsum = 0.0;

	for (int mj = -6; mj <= 6; mj++) {
		if (abs(mj) > minor_radius) continue;

		float a = float(mj) * inv_sig_minor;
		float wj = exp(-0.5 * a * a);
		vec2 base_uv = source_uv + minor_step_uv * float(mj);

		vec4 sum = vec4(0.0);
		float wsum = 0.0;

		ACCUM(need_check, base_uv, 1.0)

		for (int mi = 1; mi <= 9; mi += 2) {
			if (mi > major_radius) break;

			int mi1 = mi + 1;
			float w0 = exp(-float(mi * mi) * inv_2sig2_major);

			if (mi1 <= major_radius) {
				float w1 = exp(-float(mi1 * mi1) * inv_2sig2_major);
				float W = w0 + w1;
				float pair = (float(mi) * w0 + float(mi1) * w1) / W;

				vec2 o = major_step_uv * pair;
				ACCUM(need_check, base_uv + o, W)
				ACCUM(need_check, base_uv - o, W)
			} else {
				vec2 o = major_step_uv * float(mi);
				ACCUM(need_check, base_uv + o, w0)
				ACCUM(need_check, base_uv - o, w0)
			}
		}

		if (wsum <= EPS) {
			sum  = textureGrad(tex, clamp(base_uv, vec2(0.0), vec2(1.0)), dsource_dx_uv, dsource_dy_uv);
			wsum = 1.0;
		}

		minor_sum  += (sum / wsum) * wj;
		minor_wsum += wj;
	}

	#undef ACCUM
	#undef IN01

	return minor_sum / minor_wsum;
}

float corner_oob_ratio_at_zoom(
	int mode,
	vec2 max_rect_xy,
	float blend_strength,
	float d,
	float panini_s_param,
	float aspect,
	float zoom
) {
	float worst = 1.0;
	float invz = 1.0 / max(zoom, EPS);

	for (int i = 0; i < 4; i++) {
		vec3 ray = final_view_ray_for_screen_pos(
			CORNERS[i] * invz, mode, max_rect_xy, blend_strength, d, panini_s_param, aspect
		);

		float ratio = OOB_SENTINEL;
		if (ray.z > 0.0) {
			vec2 r = abs(ray.xy / ray.z) / max_rect_xy;
			ratio = max(r.x, r.y);
		}
		worst = max(worst, ratio);
	}
	return worst;
}

float find_corner_fit_zoom_non_panini(
	int mode,
	vec2 max_rect_xy,
	float blend_strength,
	float d,
	float panini_s_param,
	float aspect
) {
	if (corner_oob_ratio_at_zoom(mode, max_rect_xy, blend_strength, d, panini_s_param, aspect, 1.0) <= 1.0)
		return 1.0;

	float lo = 1.0;
	float hi = 1.0;

	for (int i = 0; i < 6; i++) {
		hi *= 2.0;
		if (corner_oob_ratio_at_zoom(mode, max_rect_xy, blend_strength, d, panini_s_param, aspect, hi) <= 1.0)
			break;
	}

	for (int i = 0; i < 8; i++) {
		float mid = 0.5 * (lo + hi);
		if (corner_oob_ratio_at_zoom(mode, max_rect_xy, blend_strength, d, panini_s_param, aspect, mid) > 1.0)
			lo = mid;
		else
			hi = mid;
	}

	return hi;
}

vec3 wavelength_to_xyz_1931(float nm) {
	// Analytic fits to the CIE 1931 CMFs (Wyman/Sloan/Shirley, 2013).
	const vec3 cx = vec3(442.0, 599.8, 501.1);
	const vec2 cy = vec2(568.8, 530.9);
	const vec2 cz = vec2(437.0, 459.0);

	const vec3 x_ls = vec3(0.0624, 0.0264, 0.0490);
	const vec3 x_rs = vec3(0.0374, 0.0323, 0.0382);
	const vec2 y_ls = vec2(0.0213, 0.0613);
	const vec2 y_rs = vec2(0.0247, 0.0322);
	const vec2 z_ls = vec2(0.0845, 0.0385);
	const vec2 z_rs = vec2(0.0278, 0.0725);

	const vec3 x_a  = vec3( 0.362, 1.056, -0.065);
	const vec2 y_a  = vec2( 0.821, 0.286);
	const vec2 z_a  = vec2( 1.217, 0.681);

	vec3 sx = mix(x_ls, x_rs, step(cx, vec3(nm)));
	vec2 sy = mix(y_ls, y_rs, step(cy, vec2(nm)));
	vec2 sz = mix(z_ls, z_rs, step(cz, vec2(nm)));

	vec3 tx = (vec3(nm) - cx) * sx;
	vec2 ty = (vec2(nm) - cy) * sy;
	vec2 tz = (vec2(nm) - cz) * sz;

	float X = dot(x_a, exp(-0.5 * tx * tx));
	float Y = dot(y_a, exp(-0.5 * ty * ty));
	float Z = dot(z_a, exp(-0.5 * tz * tz));

	return vec3(X, Y, Z);
}

vec3 xyz_to_linear_srgb(vec3 xyz) {
	return mat3(
		vec3( 3.2406, -0.9689,  0.0557),
		vec3(-1.5372,  1.8758, -0.2040),
		vec3(-0.4986,  0.0415,  1.0570)
	) * xyz;
}

vec3 wavelength_to_linear_srgb(float nm) {
	return max(xyz_to_linear_srgb(wavelength_to_xyz_1931(nm)), vec3(0.0));
}

float vignette_cos4(vec3 ray_dir) {
	float inv_len = inversesqrt(max(dot(ray_dir, ray_dir), EPS));
	float c = clamp(ray_dir.z * inv_len, 0.0, 1.0);
	float c2 = c * c;
	return c2 * c2;
}

float bk7_n(float nm) {
	float lam = nm * 1e-3; // um
	float l2 = lam * lam;

	float n2 = 1.0
		+ (B.x * l2) / (l2 - C.x)
		+ (B.y * l2) / (l2 - C.y)
		+ (B.z * l2) / (l2 - C.z);

	return sqrt(max(n2, EPS));
}

vec3 ca_uv_for_wavelength(vec3 base_ray, float nm, float ca_amt, vec2 max_rect_xy) {
	vec2 p = base_ray.xy / max(base_ray.z, EPS);

	float n0 = bk7_n(ca_reference_wavelength);
	float n  = bk7_n(nm);

	// raw dispersion relative to target (target stays fixed -> 0)
	float disp = n0 - n;

	// normalize by worst-case magnitude
	float wl0 = min(CA_MIN_WAVELENGTH, CA_MAX_WAVELENGTH);
	float wl1 = max(CA_MIN_WAVELENGTH, CA_MAX_WAVELENGTH);
	float d0 = n0 - bk7_n(wl0);
	float d1 = n0 - bk7_n(wl1);
	float disp_max = max(abs(d0), abs(d1));

	float disp_norm = disp / max(disp_max, EPS); // now ~[-1..1]

	// use as a relative scale
	float s = 1.0 + ca_amt * disp_norm;

	return vec3((p * s / max_rect_xy) * 0.5 + 0.5, s);
}

varying vec2 v_max_rect_xy;
varying float v_aspect;
varying float v_screen_zoom;

void vertex() {
	POSITION = vec4(UV * 2.0 - 1.0, 0.0, 1.0);

	v_aspect = 1.0;
	v_max_rect_xy = vec2(1.0);
	v_screen_zoom = 1.0;

	if (enabled){
		vec2 tex_size = vec2(textureSize(screen_tex, 0));
		v_aspect = tex_size.x / max(tex_size.y, 1.0);

		float half_tan = tan(0.5 * radians(clamp(fov_deg, 1.0, 179.0)));
		v_max_rect_xy = vec2(half_tan) * (fov_is_vertical ? vec2(v_aspect, 1.0) : vec2(1.0, 1.0 / v_aspect));

		float zoom = 1.0;
		if (fill > 0.0) {
			if (projection_mode == 1) {
				float d = strength;
				if (d > 0.0) {
					float lon_max = atan(v_max_rect_xy.x);
					float x_edge_p = abs(panini_forward(vec2(0.0, lon_max), d).x);
					if (x_edge_p > 0.0) {
						float fit_x = x_edge_p / v_max_rect_xy.x;
						zoom = mix(1.0, 1.0 / fit_x, fill);
					}
				}
			} else {
				float corner_zoom = find_corner_fit_zoom_non_panini(
					projection_mode, v_max_rect_xy, strength, strength, panini_s, v_aspect
				);
				zoom = mix(1.0, corner_zoom, fill);
			}
		}

		v_screen_zoom = zoom;
	}
}

vec4 pcg4d_hash(uvec4 x) {
	// Jarzynski, "Hash Functions for GPU Rendering" (JCGT 2020), Sec. 6.1
	x = x * 1664525u + 1013904223u;
	x.x += x.y * x.w;
	x.y += x.z * x.x;
	x.z += x.x * x.y;
	x.w += x.y * x.z;

	x ^= x >> 16u;

	x.x += x.y * x.w;
	x.y += x.z * x.x;
	x.z += x.x * x.y;
	x.w += x.y * x.z;

	return vec4(x) / vec4(4294967296.0);
}

void fragment() {
	// Compile-time limits for dynamic CA sampling
	const int MIN_CA_SAMPLES = 8;
	const int MAX_CA_SAMPLES = 64; // must cover the uniform hint range

	vec4 out_color = vec4(0.0, 0.0, 0.0, 1.0);

	if (enabled) {
		vec2 tex_size = vec2(textureSize(screen_tex, 0));
		float min_dim = max(min(tex_size.x, tex_size.y), 1.0);

		vec2 texel_uv = 1.0 / max(tex_size, vec2(1.0));
		vec2 screen_xy = (UV * 2.0 - 1.0) / max(v_screen_zoom, EPS);

		vec3 ray = final_view_ray_for_screen_pos(
			screen_xy, projection_mode, v_max_rect_xy, strength, strength, panini_s, v_aspect
		);

		if (ray.z > 0.0) {
			vec2 source_uv = (ray.xy / ray.z) / v_max_rect_xy * 0.5 + 0.5;
			vec2 duvdx = dFdx(source_uv);
			vec2 duvdy = dFdy(source_uv);

			// ---------- Vignette ----------
			float vignette_mul = 1.0;
			if (vignette_strength > EPS) {
				vignette_mul = mix(1.0, pow(max(vignette_cos4(ray), 0.0),
											gain_from_unit(vignette_spread)),
								vignette_strength);
			}

			if (vignette_mul > EPS) {
				// ---------- CA strength ----------
				float inv_len = inversesqrt(max(dot(ray, ray), EPS));
				float cos_t = clamp(ray.z * inv_len, 0.0, 1.0);

				// Angle from forward for this pixel (0 center -> larger at edges)
				float theta = acos(cos_t);

				// Normalize by the max diagonal half-angle of the *source* rectilinear camera,
				// accounting for fill zoom (so the control stays stable when fill changes).
				float theta_max = atan(length(v_max_rect_xy) / max(v_screen_zoom, EPS));
				float r = theta / max(theta_max, 1e-4);

				float ca_amt = gain_from_unit(ca_amount) * pow(r, gain_from_unit(1.0-ca_amount_spread));

				// Wavelength bounds
				float wl0 = min(CA_MIN_WAVELENGTH, CA_MAX_WAVELENGTH);
				float wl1 = max(CA_MIN_WAVELENGTH, CA_MAX_WAVELENGTH);

				// Convert "actual dispersion used" into a screen-relative quantity:
				// Measure endpoint UV separation and express it as % of min screen dimension.
				// (UV in [0..1], so multiply by min_dim to get pixels on min dimension.)
				vec3 uv0_local = ca_uv_for_wavelength(ray, wl0, ca_amt, v_max_rect_xy);
				vec3 uv1_local = ca_uv_for_wavelength(ray, wl1, ca_amt, v_max_rect_xy);
				float disp_px_min = length(uv1_local.xy - uv0_local.xy) * min_dim;

				if (disp_px_min > ca_enable_start){
					float disp_pct_min = disp_px_min / max(min_dim, 1.0);

					// Adaptive taps driven by dispersion magnitude (not the uniform):
					// taps ~= MIN + (disp_pct_min * ca_samples_per_ca * 100)
					// where ca_samples_per_ca is "samples per 1.0 (100%) of min-dimension".
					float taps_f = float(MIN_CA_SAMPLES) + disp_pct_min * ca_samples_per_ca * 100.0;

					int user_max = clamp(ca_max_samples, MIN_CA_SAMPLES, MAX_CA_SAMPLES);
					int taps = clamp(int(ceil(taps_f)), MIN_CA_SAMPLES, user_max);

					// Spectral integration (trapezoid)
					vec3 sum_rgb  = vec3(0.0);
					vec3 wsum_rgb = vec3(0.0);

					float invN = 1.0 / float(taps);

					for (int i = 0; i < MAX_CA_SAMPLES + 1; i++) {
						if (i > taps) break;

						float w_trap = (i == 0 || i == taps) ? 0.5 : 1.0;

						uvec4 key = uvec4(uvec2(FRAGCOORD.xy),
									floatBitsToUint(TIME) & (uint(ca_jitter) * 0xFFFFFFFFu), uint(i));
						float jit = pcg4d_hash(key).x;
						jit = (jit - 0.5) * 2.0;

						float u = (float(i) + jit) * invN;
						float nm = mix(wl0, wl1, u);

						vec3 uv_i = ca_uv_for_wavelength(ray, nm, ca_amt, v_max_rect_xy);
						vec3 w = wavelength_to_linear_srgb(nm);
						wsum_rgb += w * w_trap;

						if (uv_i.z < 0.0){
							continue;
						}

						vec3 s = in_01(uv_i.xy) ? textureGrad(screen_tex, uv_i.xy, duvdx, duvdy).rgb : vec3(0.0);
						sum_rgb  += (s * w) * w_trap;
					}

					out_color = vec4(sum_rgb / max(wsum_rgb, vec3(EPS)), 1.0);
				} else if (in_01(source_uv)){
					out_color = sample_anisotropic(screen_tex, source_uv, texel_uv, duvdx, duvdy);
				}
			}

			out_color.rgb *= vignette_mul;
		}
	} else {
		out_color = texture(screen_tex, SCREEN_UV);
	}

	ALBEDO = out_color.rgb;
}
