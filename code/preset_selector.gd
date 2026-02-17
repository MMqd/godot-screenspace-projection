# PresetSwitcherLabel.gd
extends Label

## Node that has the projection controller script (owns the SubViewport and drives the material).
@export var projection_node: NodePath

## Seconds to blend between compatible presets.
@export_range(0.0, 2.0, 0.01) var transition_time: float = 0.2

## Seconds to blend day/night (ambient + background + directional light) between 0 and 1.
@export_range(0.0, 2.0, 0.01) var daynight_transition_time: float = 0.2

## Update label with a short hint on start.
@export var show_hint: bool = true

var _proj: Node
var _tween: Tween
var _initialized := false

# Used to decide whether to disable pipeline when tween ends.
var _pending_disable_if_rectilinear := false

# Day/night state
var _is_day := true
var _daynight_tween: Tween

# Presets: edit values here.
const PRESETS := {
	KEY_1: {"id": 1, "name": "Rectilinear | FOV 90", "fov": 90.0,  "mode": 0, "strength": 0.0,  "fill": 1.0, "panini_s": 0.0},
	KEY_2: {"id": 2, "name": "Rectilinear | FOV 150", "fov": 150.0, "mode": 0, "strength": 0.0,  "fill": 1.0, "panini_s": 0.0},

	KEY_3: {"id": 3, "name": "Panini | FOV 90 | strength = 0.3333", "fov": 90.0,  "mode": 1, "strength": 0.3333, "fill": 1.0, "panini_s": 0.0},
	KEY_4: {"id": 4, "name": "Panini | FOV 150 | strength = 0.5", "fov": 150.0, "mode": 1, "strength": 0.5, "fill": 1.0, "panini_s": 0.0},
	KEY_5: {"id": 5, "name": "Panini | FOV 150 | strength = 0.2", "fov": 150.0,  "mode": 1, "strength": 0.2, "fill": 1.0, "panini_s": 0.0},

	KEY_6: {"id": 6, "name": "Fisheye (Stereo) | FOV 150", "fov": 150.0, "mode": 3, "strength": 1.0, "fill": 0.0, "panini_s": 0.0},
	KEY_7: {"id": 7, "name": "Fisheye (Equisolid) | FOV 150", "fov": 150.0, "mode": 4, "strength": 1.0, "fill": 0.0, "panini_s": 0.0},
	KEY_8: {"id": 8, "name": "Equirectangular | FOV 150", "fov": 150.0, "mode": 2, "strength": 1.0, "fill": 0.0, "panini_s": 0.0},
}

func _ready() -> void:
	_proj = get_node_or_null(projection_node)

	# Keybind text matches actual bindings below (1-7, Q, E)
	_update_label("Press 1-7 to switch presets.\nPress Q to toggle UI.\nPress E to toggle day/night." if show_hint else "")

	# Default day = 1
	_is_day = true
	_apply_daynight_value(1.0)

	call_deferred("_mark_initialized")

func _mark_initialized() -> void:
	_initialized = true

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var ek := event as InputEventKey

		# Q to show/hide the parent (the whole preset selector UI).
		if ek.keycode == KEY_Q:
			_toggle_parent_visible()
			get_viewport().set_input_as_handled()
			return

		# E to toggle day/night.
		if ek.keycode == KEY_E:
			_toggle_daynight()
			get_viewport().set_input_as_handled()
			return

		if PRESETS.has(ek.keycode):
			_apply_preset(PRESETS[ek.keycode])
			get_viewport().set_input_as_handled()

func _toggle_parent_visible() -> void:
	var p := get_parent()
	if p == null:
		return

	# Works for Control, Node2D, Node3D, etc.
	if "visible" in p:
		p.visible = not p.visible
	elif p is CanvasItem:
		(p as CanvasItem).visible = not (p as CanvasItem).visible

# -------------------------
# Day / Night
# -------------------------

func _toggle_daynight() -> void:
	_is_day = not _is_day
	var target := 1.0 if _is_day else 0.0
	_set_daynight(target)

func _set_daynight(target: float) -> void:
	_kill_daynight_tween()

	var do_tween := _initialized and daynight_transition_time > 0.0
	var t := daynight_transition_time if do_tween else 0.0

	if t <= 0.0:
		_apply_daynight_value(target)
		return

	var current := _get_current_daynight_value()

	_daynight_tween = create_tween()
	_daynight_tween.set_trans(Tween.TRANS_SINE)
	_daynight_tween.set_ease(Tween.EASE_IN_OUT)
	_daynight_tween.tween_method(
		func(v: float) -> void:
			_apply_daynight_value(v),
		current,
		target,
		t
	)

func _get_current_daynight_value() -> float:
	var we := _get_level0_world_environment()
	if we != null and we.environment != null:
		return float(we.environment.ambient_light_energy)
	return 1.0 if _is_day else 0.0

func _apply_daynight_value(v: float) -> void:
	v = clamp(v, 0.0, 1.0)

	# Under the SubViewport: Level0/WorldEnvironment
	var we := _get_level0_world_environment()
	if we != null and we.environment != null:
		we.environment.ambient_light_energy = v
		we.environment.background_energy_multiplier = v

	# Under the SubViewport: Level0/DirectionalLight3D
	var sun := _get_level0_directional_light()
	if sun != null:
		sun.light_energy = v

func _kill_daynight_tween() -> void:
	if _daynight_tween and _daynight_tween.is_valid():
		_daynight_tween.kill()
	_daynight_tween = null

func _get_level0_world_environment() -> WorldEnvironment:
	var vp := _get_projection_viewport()
	if vp == null:
		return null
	# If your node is literally "level0" (lowercase), change this path.
	return vp.get_node_or_null("Level0/WorldEnvironment") as WorldEnvironment

func _get_level0_directional_light() -> DirectionalLight3D:
	var vp := _get_projection_viewport()
	if vp == null:
		return null
	# If your node is literally "level0" (lowercase), change this path.
	return vp.get_node_or_null("Level0/DirectionalLight3D") as DirectionalLight3D

func _get_projection_viewport() -> Viewport:
	if _proj == null:
		return null

	var vp: Viewport = null

	# Try property access (works if the projection script exposes `viewport` as a member).
	if "viewport" in _proj:
		vp = _proj.viewport as Viewport

	# Fallback: find child by name.
	if vp == null:
		vp = _proj.get_node_or_null("ProjectionInput") as Viewport

	return vp

# -------------------------
# Presets
# -------------------------

func _apply_preset(p: Dictionary) -> void:
	if _proj == null:
		return

	_kill_tween()
	_update_label("Preset %d: %s" % [p.id, p.name])

	var do_tween := _initialized and transition_time > 0.0
	var t := transition_time if do_tween else 0.0

	var cam := _get_projection_viewport_camera()

	var target_mode: int = int(p.mode)
	var target_strength: float = float(p.strength)
	var target_fill: float = float(p.fill)
	var target_panini_s: float = float(p.panini_s)

	var current_mode := int(_proj.projection_mode)

	# We only want to disable AFTER the transition finishes, and only if final mode is rectilinear (0).
	_pending_disable_if_rectilinear = (target_mode == 0)

	# If we're going to a non-rectilinear mode, ensure pipeline is on immediately.
	if target_mode != 0:
		_set_pipeline_enabled(true)

	# First press (or no tween): snap cleanly + apply pipeline enabled state immediately.
	if t <= 0.0:
		if cam:
			cam.fov = float(p.fov)
		_proj.projection_mode = target_mode
		_proj.strength = target_strength
		_proj.fill = target_fill
		_proj.panini_s = target_panini_s
		_initialized = true

		# If rectilinear, turn pipeline off right away (no transition happening).
		_set_pipeline_enabled(target_mode != 0)
		_pending_disable_if_rectilinear = false
		return

	# One tween per press.
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.finished.connect(_on_tween_finished)

	# Camera tween.
	if cam:
		_tween.tween_property(cam, "fov", float(p.fov), t)

	var current_strength := float(_proj.strength)
	var current_fill := float(_proj.fill)
	var current_panini_s := float(_proj.panini_s)

	# Panini <-> Rectilinear smooth path (blend via Panini strength to/from 0).
	var rect_panini_pair := (
		(current_mode == 0 or current_mode == 1) and
		(target_mode == 0 or target_mode == 1)
	)
	if rect_panini_pair:
		_proj.projection_mode = 1
		if current_mode == 0:
			_proj.strength = 0.0
			current_strength = 0.0

		_tween.parallel().tween_property(_proj, "strength", (0.0 if target_mode == 0 else target_strength), t)
		_tween.parallel().tween_property(_proj, "fill", target_fill, t)
		_tween.parallel().tween_property(_proj, "panini_s", target_panini_s, t)
		_tween.tween_callback(_set_projection_mode.bind(target_mode))
		return

	# Non-Panini <-> Non-Panini:
	# Abruptly change projection FIRST, then tween other params.
	if _is_non_panini_mode(current_mode) and _is_non_panini_mode(target_mode):
		if current_mode != target_mode:
			_proj.projection_mode = target_mode

		var need_strength := not _approx(current_strength, target_strength)
		var need_fill := not _approx(current_fill, target_fill)
		var need_panini_s := not _approx(current_panini_s, target_panini_s)

		if need_strength:
			_tween.parallel().tween_property(_proj, "strength", target_strength, t)
		if need_fill:
			_tween.parallel().tween_property(_proj, "fill", target_fill, t)
		if need_panini_s:
			_tween.parallel().tween_property(_proj, "panini_s", target_panini_s, t)
		return

	# Smooth return to rectilinear when coming from non-panini modes:
	# (strength->0 first, then switch to mode 0 at the end)
	if target_mode == 0 and _is_non_panini_mode(current_mode):
		_tween.parallel().tween_property(_proj, "strength", 0.0, t)
		_tween.parallel().tween_property(_proj, "fill", target_fill, t)
		_tween.parallel().tween_property(_proj, "panini_s", target_panini_s, t)
		_tween.tween_callback(_set_projection_mode.bind(0))
		return

	# General case for switching between rectilinear (0/1) and non-panini (2/3/4/5):
	# Switch mode immediately while strength is 0, then tween up.
	if current_mode != target_mode:
		_proj.strength = 0.0
		_proj.projection_mode = target_mode

	_tween.parallel().tween_property(_proj, "strength", target_strength, t)
		# (keep as parallel so it animates together)
	_tween.parallel().tween_property(_proj, "fill", target_fill, t)
	_tween.parallel().tween_property(_proj, "panini_s", target_panini_s, t)

func _on_tween_finished() -> void:
	_tween = null
	if _pending_disable_if_rectilinear:
		_set_pipeline_enabled(false)
	_pending_disable_if_rectilinear = false

func _set_projection_mode(m: int) -> void:
	if _proj != null:
		_proj.projection_mode = m

func _set_pipeline_enabled(v: bool) -> void:
	# Projection controller script has: @export var enabled := true
	if _proj == null:
		return
	if "enabled" in _proj:
		_proj.enabled = v

func _kill_tween() -> void:
	_pending_disable_if_rectilinear = false
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null

func _approx(a: float, b: float) -> bool:
	return abs(a - b) <= 0.0001

func _is_non_panini_mode(m: int) -> bool:
	return m == 2 or m == 3 or m == 4 or m == 5

func _get_projection_viewport_camera() -> Camera3D:
	if _proj == null:
		return null

	var vp: Viewport = null

	# Try property access (works if the projection script exposes `viewport` as a member).
	if "viewport" in _proj:
		vp = _proj.viewport as Viewport

	# Fallback: find child by name.
	if vp == null:
		vp = _proj.get_node_or_null("ProjectionInput") as Viewport

	if vp == null:
		return null

	return vp.get_camera_3d()

func _update_label(s: String) -> void:
	text = s
