extends Camera3D

# Movement settings
@export var move_speed: float = 20.0
@export var sprint_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.002

# Camera rotation
var rotation_x: float = 0.0
var rotation_y: float = 0.0

# Mouse capture
var mouse_captured: bool = false

func _ready():
	# Start at a good viewing height
	global_position = Vector3(0, 50, 0)

	# CRITICAL FIX: Disable wireframe mode
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	print("Viewport debug draw mode disabled (normal rendering)")

	print("=== FREE FLY CAMERA CONTROLS ===")
	print("Right Click: Capture/Release mouse")
	print("WASD: Move horizontally")
	print("Space: Move up")
	print("Ctrl: Move down")
	print("Shift: Sprint (3x speed)")
	print("Mouse: Look around (when captured)")
	print("================================")

func _input(event):
	# Right click to capture/release mouse
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			toggle_mouse_capture()

	# Mouse motion for camera rotation
	if event is InputEventMouseMotion and mouse_captured:
		rotation_y -= event.relative.x * mouse_sensitivity
		rotation_x -= event.relative.y * mouse_sensitivity
		rotation_x = clamp(rotation_x, -PI/2, PI/2)

func _process(delta):
	# Apply rotation
	rotation.x = rotation_x
	rotation.y = rotation_y

	# Don't process movement if mouse isn't captured
	if not mouse_captured:
		return

	# Calculate movement
	var input_dir = Vector3.ZERO

	# Forward/Backward (W/S)
	if Input.is_key_pressed(KEY_W):
		input_dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		input_dir += transform.basis.z

	# Left/Right (A/D)
	if Input.is_key_pressed(KEY_A):
		input_dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		input_dir += transform.basis.x

	# Up/Down (Space/Ctrl)
	if Input.is_key_pressed(KEY_SPACE):
		input_dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		input_dir -= Vector3.UP

	# Normalize to prevent faster diagonal movement
	if input_dir.length() > 0:
		input_dir = input_dir.normalized()

	# Apply sprint
	var current_speed = move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		current_speed *= sprint_multiplier

	# Move the camera
	global_position += input_dir * current_speed * delta

func toggle_mouse_capture():
	mouse_captured = !mouse_captured

	if mouse_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		print("Mouse captured - use WASD to fly around")
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		print("Mouse released")
