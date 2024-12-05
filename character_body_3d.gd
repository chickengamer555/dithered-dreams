extends CharacterBody3D

@export var speed : float = 70.0  # PS1-like movement speed
@export var rotation_speed : float = 1.5  # PS1-like turning speed
@export var gravity : float = 10 # Gravity value
@export var max_look_angle : float = 90.0  # Max angle to look fully up or down

@onready var camera = $Camera3D

var last_position = Vector3.ZERO  # Last recorded position
var is_moving = false  # Is the player moving?

func _ready():
	# Initialize last_position to the player's starting position
	last_position = global_transform.origin

func _physics_process(delta: float) -> void:
	# Add gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Input for movement - Tank Controls
	var direction = Vector3.ZERO
	if Input.is_action_pressed("ui_up"):
		direction -= transform.basis.z
	elif Input.is_action_pressed("ui_down"):
		direction += transform.basis.z

	# Apply movement speed
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	# Handle player rotation (left and right)
	if Input.is_action_pressed("look_left"):
		rotate_y(rotation_speed * delta)
	elif Input.is_action_pressed("look_right"):
		rotate_y(-rotation_speed * delta)

	# Handle camera look up and look down
	if camera:
		var camera_rotation = camera.rotation_degrees.x
		if Input.is_action_pressed("look_up"):
			camera_rotation += rotation_speed * delta * 40.0  # Adjust sensitivity as needed
		elif Input.is_action_pressed("look_down"):
			camera_rotation -= rotation_speed * delta * 30.0  # Adjust sensitivity as needed
		camera_rotation = clamp(camera_rotation, -max_look_angle, max_look_angle)
		camera.rotation_degrees.x = camera_rotation

	# Move the player
	move_and_slide()

	# Check if the player has moved since the last frame
	is_moving = (global_transform.origin.distance_to(last_position) > 0.01)  # Adjust threshold if necessary
	last_position = global_transform.origin

	# Inform the world about the player's movement state
	var world_node = get_node("/root/world")  # Adjust the path if necessary
	if world_node:
		world_node.update_nightmare_and_dream_speed(is_moving)
	else:
		print("World node not found!")

# Map your input actions in the Input Map in Project Settings.
# Use "ui_up", "ui_down" for movement, and "look_up", "look_down", "look_left", "look_right" for camera control.
