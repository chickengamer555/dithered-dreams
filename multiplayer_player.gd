extends CharacterBody3D

@export var speed : float = 7.0  # PS1-like movement speed
@export var rotation_speed : float = 1.3  # PS1-like turning speed
@export var gravity : float = 9  # Gravity value
@export var jump_velocity : float = 10.0  # Jump velocity
@export var max_look_angle : float = 90.0  # Max angle to look fully up or down

@onready var camera = $Camera3D
@onready var mesh = $MeshInstance3D
@onready var voice_player_3d = $VoicePlayer3D

var last_position = Vector3.ZERO  # Last recorded position
var is_moving = false  # Is the player moving?

# Voice chat variables
var voice_playback: AudioStreamGeneratorPlayback = null
var voice_buffer: PackedByteArray = PackedByteArray()
const VOICE_SAMPLE_RATE = 48000

func _ready():
	# Initialize last_position to the player's starting position
	last_position = global_transform.origin

	# Set up multiplayer authority
	# Only the owner of this player can control it
	set_multiplayer_authority(str(name).to_int())

	print("MultiplayerPlayer _ready - Name: ", name, " Authority: ", get_multiplayer_authority(), " Is Authority: ", is_multiplayer_authority())
	print("Player position: ", global_position)
	print("Camera position: ", camera.global_position if camera else "NO CAMERA")

	# Only show camera for the local player
	if is_multiplayer_authority():
		# Make sure camera is at proper eye level
		camera.position = Vector3(0, 0.6, 0)
		# Hide our own mesh so we don't see it
		mesh.visible = false

		# CRITICAL: Wait a frame to ensure old cameras are removed, then activate
		await get_tree().process_frame
		await get_tree().process_frame  # Wait 2 frames to be absolutely sure

		camera.current = true
		camera.make_current()  # Force it to be current

		print("LOCAL PLAYER: Camera activated for peer ", name, " at position ", camera.global_position)
		print("Camera current: ", camera.current)
		print("Camera FOV: ", camera.fov)
		print("Camera far plane: ", camera.far)

		# Verify camera is actually current
		await get_tree().process_frame
		var viewport = get_viewport()
		if viewport:
			var active_cam = viewport.get_camera_3d()
			print("Viewport active camera: ", active_cam)
			if active_cam == camera:
				print("✓ Camera successfully activated!")
			else:
				print("✗ WARNING: Camera not active! Active camera is: ", active_cam)

		# Disable voice player for local player (don't hear yourself)
		voice_player_3d.queue_free()
	else:
		camera.current = false
		# Show other players' meshes
		mesh.visible = true
		print("REMOTE PLAYER: Showing mesh for peer ", name)

		# Set up voice receiver for remote players
		setup_voice_receiver()

func _physics_process(delta: float) -> void:
	# REMOTE PLAYERS: Just return, let the MultiplayerSynchronizer handle it
	# The synced properties will be updated automatically
	if not is_multiplayer_authority():
		return

	# LOCAL PLAYER: Process input and physics
	# Add gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	# Input for movement - Tank Controls
	var direction = Vector3.ZERO
	if Input.is_action_pressed("ui_up"):
		direction -= transform.basis.z.normalized()
	elif Input.is_action_pressed("ui_down"):
		direction += transform.basis.z.normalized()

	# Apply movement speed to the direction
	direction = direction * speed

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
	var look_input = 0.0
	if Input.is_action_pressed("look_up"):
		look_input -= 1.0
	elif Input.is_action_pressed("look_down"):
		look_input += 1.0

	# Apply camera rotation
	if camera:
		var current_rotation = camera.rotation_degrees
		current_rotation.x += look_input * rotation_speed * 50 * delta
		current_rotation.x = clamp(current_rotation.x, -max_look_angle, max_look_angle)
		camera.rotation_degrees = current_rotation

	# Check if the player is moving
	var current_position = global_transform.origin
	is_moving = (current_position.distance_to(last_position) > 0.01)
	last_position = current_position

func setup_voice_receiver():
	"""Set up voice playback for remote players with proximity audio"""
	if not voice_player_3d:
		return

	# Create audio stream generator for voice playback
	var stream = AudioStreamGenerator.new()
	stream.mix_rate = VOICE_SAMPLE_RATE
	stream.buffer_length = 0.1  # 100ms buffer

	voice_player_3d.stream = stream
	voice_player_3d.play()
	voice_playback = voice_player_3d.get_stream_playback()

	print("Voice receiver set up for remote player ", name)

func receive_voice_data(decompressed_voice: PackedByteArray):
	"""Receive and play voice data from network"""
	if voice_playback == null:
		return

	# Add to buffer
	voice_buffer.append_array(decompressed_voice)

	# Process buffer and push to audio stream
	while voice_buffer.size() >= 2 and voice_playback.get_frames_available() > 0:
		# Convert 16-bit PCM to float amplitude (-1.0 to 1.0)
		var raw_value: int = voice_buffer[0] | (voice_buffer[1] << 8)
		raw_value = (raw_value + 32768) & 0xffff
		var amplitude: float = float(raw_value - 32768) / 32768.0

		# Push to both channels (mono to stereo)
		# AudioStreamPlayer3D will handle 3D positioning
		voice_playback.push_frame(Vector2(amplitude, amplitude))

		# Remove processed samples
		voice_buffer.remove_at(0)
		voice_buffer.remove_at(0)

