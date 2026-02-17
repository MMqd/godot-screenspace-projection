extends CharacterBody3D

@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.0

@export var ground_accel: float = 28.0
@export var ground_decel: float = 34.0
@export var air_accel: float = 6.0
@export var air_control: float = 0.25

@export var jump_velocity: float = 4.0

@export var gravity_scale: float = 1.0
@export var fall_gravity_multiplier: float = 1.0
@export var jump_cut_multiplier: float = 1.0

@export var mouse_sensitivity: float = 250.0
@export var max_look_up: float = 89.0
@export var max_look_down: float = -89.0

@export var camera_path: NodePath = ^"Camera3D"
@export var capture_on_click: bool = true

@export var camera_offset: Vector3 = Vector3(0.0, 1.65, 0.0)

var base_gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _pitch_deg: float = 0.0
var _yaw_deg: float = 0.0
var _has_focus: bool = true
var _mouse_accum: Vector2 = Vector2.ZERO
var _jump: bool = false

@onready var cam: Camera3D = get_node(camera_path) as Camera3D

var _prev_pos: Vector3
var _curr_pos: Vector3
var _prev_yaw: float
var _curr_yaw: float
var _initialized := false

func _ready() -> void:
	_has_focus = DisplayServer.window_is_focused()

	_yaw_deg = rad_to_deg(rotation.y)
	_pitch_deg = rad_to_deg(cam.rotation.x)

	if _has_focus:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_prev_pos = global_position
	_curr_pos = global_position
	_prev_yaw = _yaw_deg
	_curr_yaw = _yaw_deg
	_initialized = true

	_update_camera_visual(1.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_has_focus = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_has_focus = false
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _unhandled_input(event: InputEvent) -> void:
	if capture_on_click and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if DisplayServer.window_is_focused():
				_has_focus = true
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				get_viewport().set_input_as_handled()

	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if event.is_action_pressed("jump"):
		_jump = true
	if event.is_action_released("jump"):
		_jump = false

	if event is InputEventMouseMotion:
		if _has_focus and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			_mouse_accum += event.screen_relative / min(DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y)

func _process(_delta: float) -> void:
	if not _initialized:
		return
	var t := Engine.get_physics_interpolation_fraction()
	_update_camera_visual(t)

func _update_camera_visual(t: float) -> void:
	var p := _prev_pos.lerp(_curr_pos, t)
	var y0 := deg_to_rad(_prev_yaw)
	var y1 := deg_to_rad(_curr_yaw)
	var yi := lerp_angle(y0, y1, t)

	var b := Basis(Vector3.UP, yi)
	var cam_pos := p + b * camera_offset

	cam.global_transform = Transform3D(b, cam_pos)
	cam.rotation.x = deg_to_rad(_pitch_deg)

func _physics_process(delta: float) -> void:
	if _has_focus and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw_deg += -_mouse_accum.x * mouse_sensitivity
		_pitch_deg = clamp(_pitch_deg + -_mouse_accum.y * mouse_sensitivity, max_look_down, max_look_up)
	_mouse_accum = Vector2.ZERO

	rotation.y = deg_to_rad(_yaw_deg)

	var g := base_gravity * gravity_scale

	if not is_on_floor():
		var mult := 1.0
		if velocity.y < 0.0:
			mult = fall_gravity_multiplier
		elif not _jump:
			mult = jump_cut_multiplier
		velocity.y -= g * mult * delta
	else:
		if velocity.y < 0.0:
			velocity.y = -2.0

	if _jump and is_on_floor():
		velocity.y = jump_velocity

	var input_vec := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish_dir := (global_transform.basis * Vector3(input_vec.x, 0.0, input_vec.y)).normalized()

	var target_speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	var target_vel := wish_dir * target_speed

	var horiz := Vector3(velocity.x, 0.0, velocity.z)

	if is_on_floor():
		var rate := ground_accel if wish_dir != Vector3.ZERO else ground_decel
		horiz = horiz.move_toward(target_vel, rate * delta)
	else:
		var desired := horiz.lerp(target_vel, air_control)
		horiz = horiz.move_toward(desired, air_accel * delta)

	velocity.x = horiz.x
	velocity.z = horiz.z

	_prev_pos = _curr_pos
	_curr_pos = global_position
	_prev_yaw = _curr_yaw
	_curr_yaw = _yaw_deg

	move_and_slide()
