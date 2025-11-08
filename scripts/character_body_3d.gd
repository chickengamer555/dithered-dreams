extends CharacterBody3D

@export var speed : float = 15.0  # PS1-like movement speed
@export var sprint_speed_multiplier : float = 1.8  # Sprint speed multiplier
@export var rotation_speed : float = 1.5  # PS1-like turning speed
@export var gravity : float = 9  # Gravity value
@export var jump_velocity : float = 10.0  # Jump velocity
@export var max_look_angle : float = 90.0  # Max angle to look fully up or down

@onready var camera = $Camera3D

var last_position = Vector3.ZERO  # Last recorded position
var is_moving = false  # Is the player moving?

# Sprint/Stamina system
var stamina : float = 100.0  # Current stamina
var max_stamina : float = 100.0  # Maximum stamina
var stamina_drain_rate : float = 25.0  # Stamina drain per second while sprinting
var stamina_regen_rate : float = 15.0  # Stamina regen per second when not sprinting
var is_sprinting : bool = false  # Is the player currently sprinting?

func _ready():
	# Initialize last_position to the player's starting position
	last_position = global_transform.origin

func _physics_process(delta: float) -> void:
	# Add gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	# Handle sprinting and stamina
	var is_trying_to_sprint = Input.is_action_pressed("sprint") and is_on_floor()
	var is_moving_forward = Input.is_action_pressed("ui_up")

	if is_trying_to_sprint and is_moving_forward and stamina > 0:
		is_sprinting = true
		stamina -= stamina_drain_rate * delta
		stamina = max(stamina, 0.0)
	else:
		is_sprinting = false
		# Regenerate stamina when not sprinting
		if stamina < max_stamina:
			stamina += stamina_regen_rate * delta
			stamina = min(stamina, max_stamina)

	# Notify world script to update sprint meter
	var world_node = get_node_or_null("/root/world")
	if world_node and world_node.has_method("update_sprint_meter"):
		world_node.update_sprint_meter(stamina)

	# Input for movement - Tank Controls
	var direction = Vector3.ZERO
	if Input.is_action_pressed("ui_up"):
		direction -= transform.basis.z.normalized()
	elif Input.is_action_pressed("ui_down"):
		direction += transform.basis.z.normalized()

	# Apply movement speed to the direction (with sprint multiplier if sprinting)
	var current_speed = speed * (sprint_speed_multiplier if is_sprinting else 1.0)
	direction = direction * current_speed

	# Update velocity
	velocity.x = direction.x
	velocity.z = direction.z

	# Move the player
	move_and_slide()

	# Handle player rotation (left and right)
	if Input.is_action_pressed("look_left"):
		rotate_y(rotation_speed * delta)
	elif Input.is_action_pressed("look_right"):
		rotate_y(-rotation_speed * delta)

	# Handle camera look up and look down
	if camera:
		var camera_rotation = camera.rotation_degrees.x
		if Input.is_action_pressed("look_up"):
			camera_rotation += rotation_speed * delta * 30.0  # Adjust sensitivity as needed
		elif Input.is_action_pressed("look_down"):
			camera_rotation -= rotation_speed * delta * 30.0  # Adjust sensitivity as needed
		camera_rotation = clamp(camera_rotation, -max_look_angle, max_look_angle)
		camera.rotation_degrees.x = camera_rotation

	# Check if the player has moved since the last frame
	is_moving = (global_transform.origin.distance_to(last_position) > 0.01)  # Adjust threshold if necessary
	last_position = global_transform.origin

	# Inform the world about the player's movement state
	if world_node:
		world_node.update_nightmare_and_dream_speed(is_moving)
	# else: Don't spam - world_node is optional in test scenes

# Map your input actions in the Input Map in Project Settings.
# Use "ui_up", "ui_down" for movement, "ui_accept" for jumping, and "look_up", "look_down", "look_left", "look_right" for camera control.
