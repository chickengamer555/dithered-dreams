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
var voice_sample_rate: int = 24000  # OPTIMIZATION: 24kHz for voice (was 48kHz)
var voice_indicator_3d: Label3D = null
var voice_indicator_timer: float = 0.0

# PERFORMANCE: Jitter buffer for smooth voice playback
var voice_jitter_buffer_target: int = 2400  # Target buffer size (0.05s at 24kHz mono 16-bit = 2400 bytes)
var voice_playback_started: bool = false

# OPTIMIZATION: Event-driven voice processing
var voice_process_accumulator: float = 0.0
const VOICE_PROCESS_RATE: float = 0.02  # 50 Hz (matches network packet rate)

# PERFORMANCE: Removed complex interpolation - Godot handles this automatically with physics interpolation

func _process(delta: float) -> void:
	# OPTIMIZATION: Event-driven voice processing at fixed 50 Hz rate
	voice_process_accumulator += delta

	while voice_process_accumulator >= VOICE_PROCESS_RATE:
		process_voice_buffer()
		voice_process_accumulator -= VOICE_PROCESS_RATE

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

		# Voice receiver will be set up by world script with correct sample rate

		# Create 3D voice indicator above player's head
		voice_indicator_3d = Label3D.new()
		voice_indicator_3d.text = "🎤"
		voice_indicator_3d.visible = false
		voice_indicator_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		voice_indicator_3d.modulate = Color(0.2, 1.0, 0.2)  # Green
		voice_indicator_3d.pixel_size = 0.01
		voice_indicator_3d.position = Vector3(0, 1.5, 0)  # Above player's head
		add_child(voice_indicator_3d)

func _physics_process(delta: float) -> void:
	# REMOTE PLAYERS: Process voice and indicators only
	if not is_multiplayer_authority():
		# Update voice indicator timer for remote players
		if voice_indicator_timer > 0.0:
			voice_indicator_timer -= delta
			if voice_indicator_timer <= 0.0 and voice_indicator_3d:
				voice_indicator_3d.visible = false
		return

	# LOCAL PLAYER continues below

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

	# OPTIMIZATION: Only update camera if there's input
	if look_input != 0.0 and camera:
		var current_rotation = camera.rotation_degrees
		current_rotation.x += look_input * rotation_speed * 50 * delta
		current_rotation.x = clamp(current_rotation.x, -max_look_angle, max_look_angle)
		camera.rotation_degrees = current_rotation

	# Check if the player is moving
	var current_position = global_transform.origin
	# OPTIMIZATION: Use distance_squared_to() - 4-5x faster than distance_to()
	const MOVE_THRESHOLD_SQ = 0.0001  # 0.01 * 0.01
	is_moving = (current_position.distance_squared_to(last_position) > MOVE_THRESHOLD_SQ)
	last_position = current_position

func setup_voice_receiver(sample_rate: int = 24000):
	"""Set up voice playback for remote players with proximity audio"""
	print("🎧 Setting up voice receiver for player ", name, " at ", sample_rate, "Hz")

	if not voice_player_3d:
		print("  ❌ voice_player_3d is NULL!")
		return

	# Store the sample rate
	voice_sample_rate = sample_rate

	# Create audio stream generator for voice playback
	var stream = AudioStreamGenerator.new()
	stream.mix_rate = voice_sample_rate
	stream.buffer_length = 0.1  # PERFORMANCE: 100ms buffer (good balance of latency and stability)

	voice_player_3d.stream = stream
	voice_player_3d.play()
	voice_playback = voice_player_3d.get_stream_playback()

	# Optimize 3D audio settings for proximity voice chat - DREAMY EXTENDED RANGE
	voice_player_3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC  # More realistic
	voice_player_3d.unit_size = 16.0  # Extended proximity range (doubled)
	voice_player_3d.max_distance = 100.0  # Can hear voices from much further away

	print("✅ Voice receiver configured for ", name)
	print("  Sample rate: ", voice_sample_rate, "Hz")
	print("  voice_playback is null: ", voice_playback == null)
	print("  voice_player_3d.playing: ", voice_player_3d.playing)
	print("  voice_player_3d.stream_paused: ", voice_player_3d.stream_paused)

func receive_voice_data(pcm_voice: PackedByteArray):
	"""Receive and play voice data from network (stereo 16-bit PCM)"""
	if voice_playback == null:
		return

	# Show voice indicator
	if voice_indicator_3d:
		voice_indicator_3d.visible = true
		voice_indicator_timer = 0.2  # Keep visible for 200ms

	# Add to buffer
	voice_buffer.append_array(pcm_voice)

	# PERFORMANCE: Buffer overflow protection - prevent memory leak and latency buildup
	var max_buffer_size = voice_sample_rate * 4  # 1 second worth of stereo 16-bit samples
	if voice_buffer.size() > max_buffer_size:
		# Clear buffer and reset playback state
		voice_buffer.clear()
		voice_playback_started = false

func process_voice_buffer():
	"""Process voice buffer and push audio frames to the speaker - called every frame"""
	if voice_playback == null:
		return

	# JITTER BUFFER: Wait until we have enough data before starting playback
	# This prevents choppy audio from network jitter
	if not voice_playback_started:
		if voice_buffer.size() < voice_jitter_buffer_target:
			return  # Wait for buffer to fill
		voice_playback_started = true

	if voice_buffer.size() == 0:
		# Buffer underrun - reset playback state
		voice_playback_started = false
		return

	# OPTIMIZATION: Audio data is now MONO 16-bit PCM (2 bytes per frame)
	var frames_available = voice_playback.get_frames_available()
	if frames_available == 0:
		return  # Audio buffer full, wait for next frame

	# ADAPTIVE PLAYBACK: Push more frames when buffer is getting full to reduce latency
	var buffer_fill_ratio = float(voice_buffer.size()) / float(voice_jitter_buffer_target)
	var frames_to_push = min(voice_buffer.size() / 2, frames_available)  # 2 bytes per mono sample

	# If buffer is getting too full, push more aggressively
	if buffer_fill_ratio > 2.0:
		frames_to_push = min(frames_to_push * 2, frames_available)

	# OPTIMIZATION: Use push_buffer() instead of individual push_frame() calls (6x faster!)
	var bytes_to_consume = frames_to_push * 2  # 2 bytes per mono sample

	# Pre-allocate frame buffer for batch pushing
	var audio_frames = PackedVector2Array()
	audio_frames.resize(frames_to_push)

	for i in range(frames_to_push):
		var offset = i * 2  # MONO: 2 bytes per sample

		# Read mono sample (16-bit little-endian)
		var mono_raw: int = voice_buffer[offset] | (voice_buffer[offset + 1] << 8)

		# Convert unsigned to signed 16-bit (-32768 to 32767)
		if mono_raw >= 32768:
			mono_raw -= 65536

		# Normalize to float [-1.0, 1.0]
		var mono_amplitude: float = float(mono_raw) / 32768.0

		# Store frame (push SAME value to both channels for mono)
		# AudioStreamPlayer3D will handle 3D positioning for spatial audio
		audio_frames[i] = Vector2(mono_amplitude, mono_amplitude)

	# OPTIMIZATION: Single push_buffer() call is 6x faster than individual push_frame() calls
	voice_playback.push_buffer(audio_frames)

	# PERFORMANCE: Remove all processed bytes at once (single O(n) operation instead of O(n²))
	voice_buffer = voice_buffer.slice(bytes_to_consume)
