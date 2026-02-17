extends Node3D

## Viewport used to render the 3D scene. Its texture is sampled by the projection shader.
@onready var viewport: Viewport = $ProjectionInput

## Fullscreen mesh that displays the post-processed result (projection + CA + vignette).
@onready var out_mesh: MeshInstance3D = $_ProjectionOutput


## Master enable for the whole pipeline.
## When false, the offscreen viewport renders at native size and the shader is disabled (passthrough).
@export var enabled := true

## Linear resolution multiplier applied to the offscreen viewport size.
## 1.0 = native, 2.0 = 2x width/height.
@export_range(0.0, 10.0) var upscale: float = 2.0

## How much the 3D render resolution follows the enlarged viewport size.
## 0.0 = render at ~1/upscale (cheap), 1.0 = render at full enlarged size (expensive).
@export_range(0.0, 1.0) var supersample_upscale_amount: float = 0.5

@export_group("Projection")

## Projection model.
## Rectilinear: preserves straight lines.
## Panini: preserves vertical straight lines (and central horizontals).
## Equirectangular (lat-long): uniform latitude / longitude sampling.
## Fisheye Stereographic: preserves angles (conformal).
## Fisheye Equisolid: preserves solid angle (equal area on the sphere).
@export_enum(
	"Rectilinear:0",
	"Panini:1",
	"Equirectangular (lat-long):2",
	"Fisheye Stereographic:3",
	"Fisheye Equisolid:4"
) var projection_mode: int = 1


## Strength.
## Panini: D (0..1). Other modes: blend (0 = rectilinear, 1 = full projection).
@export_range(0.0, 1.0) var strength: float = 0.5

## Fill (auto-zoom) to remove empty corners.
## 0 = none, 1 = minimal crop that keeps corners valid.
@export_range(0.0, 1.0) var fill: float = 1.0

## Panini vertical compensation for very wide angles.
@export_range(-1.0, 1.0) var panini_s: float = 0.0


@export_group("Projection/Sampling")

## Anisotropic filter radius caps (quality vs cost) for the base sample.
@export_range(1, 9, 1) var max_major_radius: int = 5
@export_range(0, 6, 1) var max_minor_radius: int = 3


@export_group("Chromatic Aberration")

## Lateral chromatic aberration amount (0 = none).
@export_range(0.0, 1.0) var ca_amount: float = 0.0

## Where CA grows (lower = edge-only, higher = broader).
@export_range(0.01, 1.0) var ca_amount_spread: float = 0.5

## Reference wavelength (nm) used as the "no shift" anchor for dispersion.
@export_range(360.0, 730.0) var ca_reference_wavelength: float = 540.0

## CA pixel activation threshold.
## Below this (after internal shaping), the shader bypasses spectral sampling and uses the base sample.
@export_range(0.0, 5.0) var ca_enable_start: float = 0.5

## Time-based spectral tap jitter to reduce banding in CA.
@export var ca_jitter: bool = true

## Upper cap for adaptive CA wavelength intervals (shader uniform: ca_max_samples).
## Higher = smoother CA at strong dispersion, higher cost.
@export_range(8, 64, 1) var ca_max_samples: int = 16

## Adaptive CA density (shader uniform: ca_samples_per_ca).
## Scales taps based on measured dispersion (endpoint UV separation), normalized by the screen's min dimension.
## Higher = more taps sooner as dispersion grows.
@export_range(0.0, 8.0) var ca_samples_per_ca: float = 0.5


@export_group("Vignette")

## Vignette strength (0 = none).
@export_range(0.0, 1.0) var vignette_strength: float = 0.0

## Vignette falloff (lower = edge-only, higher = wider).
@export_range(0.0, 1.0) var vignette_spread: float = 0.5


func _ready() -> void:
	if viewport and out_mesh and out_mesh.material_override:
		out_mesh.material_override.set_shader_parameter("screen_tex", viewport.get_texture())
		_apply_shader_params()


func _unhandled_input(event: InputEvent) -> void:
	if viewport:
		viewport.push_input(event)


func _process(_delta: float) -> void:
	if out_mesh:
		out_mesh.visible = not Engine.is_editor_hint()

		var actual_upscale: float = upscale if enabled else 1.0
		var new_size: Vector2 = DisplayServer.window_get_size() * actual_upscale

		const MIN_VIEWPORT_SIZE := 64
		if min(new_size.x, new_size.y) < MIN_VIEWPORT_SIZE:
			new_size = Vector2.ONE * MIN_VIEWPORT_SIZE
			actual_upscale = 1.0

		if viewport:
			if viewport.size != Vector2i(new_size):
				viewport.size = Vector2i(new_size)

			if viewport.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR:
				viewport.scaling_3d_scale = 1.0
			else:
				viewport.scaling_3d_scale = min(
					1.0 / lerp(actual_upscale, 1.0, sqrt(supersample_upscale_amount)),
					1.0
				)

			if out_mesh.material_override:
				out_mesh.material_override.set_shader_parameter("enabled", enabled)
				_apply_shader_params()

				var camera := viewport.get_camera_3d() as Camera3D
				if camera \
				and camera.projection == Camera3D.PROJECTION_PERSPECTIVE \
				and out_mesh.material_override is ShaderMaterial:
					out_mesh.material_override.set_shader_parameter("fov_deg", camera.fov)
					out_mesh.material_override.set_shader_parameter(
						"fov_is_vertical",
						camera.keep_aspect == Camera3D.KeepAspect.KEEP_HEIGHT
					)


func _apply_shader_params() -> void:
	var mat := out_mesh.material_override
	if mat == null or not (mat is ShaderMaterial):
		return

	# Projection
	mat.set_shader_parameter("projection_mode", projection_mode)
	mat.set_shader_parameter("strength", strength)
	mat.set_shader_parameter("fill", fill)
	mat.set_shader_parameter("panini_s", panini_s)

	# Chromatic aberration
	mat.set_shader_parameter("ca_amount", ca_amount)
	mat.set_shader_parameter("ca_amount_spread", ca_amount_spread)
	mat.set_shader_parameter("ca_reference_wavelength", ca_reference_wavelength)
	mat.set_shader_parameter("ca_enable_start", ca_enable_start)
	mat.set_shader_parameter("ca_jitter", ca_jitter)
	mat.set_shader_parameter("ca_max_samples", ca_max_samples)
	mat.set_shader_parameter("ca_samples_per_ca", ca_samples_per_ca)

	# Vignette
	mat.set_shader_parameter("vignette_strength", vignette_strength)
	mat.set_shader_parameter("vignette_spread", vignette_spread)

	# Sampling
	mat.set_shader_parameter("max_major_radius", max_major_radius)
	mat.set_shader_parameter("max_minor_radius", max_minor_radius)
