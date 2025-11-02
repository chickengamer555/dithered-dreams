extends Node

@onready var worlds = { # Sets up the dictionaries of what worlds there are
	"world1": $SubViewportContainer/SubViewport/world1,
	"world2": $SubViewportContainer/SubViewport/world2,
}

@onready var nightmares = { # Sets up the dictionaries of what nightmares there are
	"nightmare1": $SubViewportContainer/SubViewport/nightmare1,
	"nightmare2": $SubViewportContainer/SubViewport/nightmare2,

}

# Multiplayer
var multiplayer_player_scene = preload("res://multiplayer_player.tscn")
var players = {}  # Dictionary to store player nodes by peer ID
var is_multiplayer = false

# Voice chat - Godot microphone-based
var is_recording: bool = false
var voice_sample_rate: int = 24000  # OPTIMIZATION: 24kHz is ideal for voice (48kHz is overkill)
var mic_player: AudioStreamPlayer = null
var mic_effect: AudioEffectCapture = null
var voice_send_timer: float = 0.0
var voice_send_interval: float = 0.05  # PERFORMANCE: Send voice packets every 50ms (20 packets/sec) - better sync

# OPTIMIZATION: Rate limiting for nightmare value sync
var nightmare_sync_timer: float = 0.0
const NIGHTMARE_SYNC_INTERVAL: float = 0.2  # Sync 5 times per second instead of 60

# OPTIMIZATION: Proximity-based voice chat (send only to nearby players)
const VOICE_HEAR_DISTANCE: float = 60.0  # Can hear players within 60 units (2x range)
const VOICE_HEAR_DISTANCE_SQ: float = 3600.0  # Pre-computed squared distance (60*60)

var environments = { # Loads the environment resources for each world and nightmare
	"world1": preload("res://envoirments/world1.tres"),
	"nightmare1": preload("res://envoirments/nightmare1.tres"),
	"world2": preload("res://envoirments/world2.tres"),
	"nightmare2": preload("res://envoirments/nightmare2.tres"),
	# Add other environments as needed
}
@onready var world_environment = $WorldEnvironment  # Reference to the WorldEnvironment node

@onready var timer_label = $CanvasLayer/Label
@onready var nightmare_bar = $CanvasLayer/NightmareBar
@onready var transition_rect = $CanvasLayer/ColorRect  # Reference to the ColorRect for transitions

# Interaction UI (will be created dynamically)
var interaction_label: Label = null
var interaction_progress_bar: ProgressBar = null

# Voice chat UI
var voice_indicator: Label = null
var voice_indicator_timer: float = 0.0
var voice_settings_ui: Control = null

@export var play_time: int = 300
@export var main_menu_scene: PackedScene
var time_left: int = play_time
var timer: Timer

var world_timer: Timer
var time_in_world: float = 0.0
@export var time_before_nightmare: float = 45.0

@export var nightmare_chance: float = 25.0
@export var world_chance: float = 75.0

var current_world_name: String = "world1"

var nightmare_value = 0.0
var nightmare_speed = 0.0
@export var nightmare_increment: float = 2.0

var dream_value = 0.0
@export var dream_increment: float = 0.2

# Dictionaries to store original collision layers and masks
var original_collision_layers = {}
var original_collision_masks = {}

# Flag to indicate if a transition is in progress
var is_transitioning: bool = false

func _ready():
	randomize()  # Starts random number generator
	nightmare_bar.value = nightmare_value  # Sets up the nightmare bar based on var

	# NOTE: Audio settings are now loaded in main_menu.gd BEFORE world instantiation
	# This ensures AudioStreamPlayer nodes with autoplay=true respect the volume settings

	# Check if we're in multiplayer mode
	is_multiplayer = multiplayer.has_multiplayer_peer()

	var viewport = $SubViewportContainer/SubViewport

	if is_multiplayer:
		print("Multiplayer mode detected!")
		print("Is server: ", multiplayer.is_server())
		print("My peer ID: ", multiplayer.get_unique_id())
		print("Connected peers: ", multiplayer.get_peers())

		# Set up multiplayer callbacks
		multiplayer.peer_connected.connect(_on_player_connected)
		multiplayer.peer_disconnected.connect(_on_player_disconnected)

		# FIX: If we're a client and already connected, notify server immediately
		# (the connected_to_server signal may have already fired in main_menu)
		if not multiplayer.is_server():
			print("CLIENT: World loaded, notifying server we're ready...")
			# Use call_deferred to ensure world is fully initialized first
			call_deferred("_notify_server_ready")

		# IMMEDIATELY disable and remove the original single-player player
		var old_player = $SubViewportContainer/SubViewport/Player
		if old_player:
			# First, disable its camera to prevent conflicts
			var old_camera = old_player.get_node_or_null("Camera3D")
			if old_camera:
				old_camera.current = false

			# Remove it from the scene tree immediately
			old_player.get_parent().remove_child(old_player)
			old_player.queue_free()

	# Disable all worlds initially
	for _world_name in worlds.keys():
		var world_iter = worlds[_world_name]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)

	# Disable all nightmares initially
	for _nightmare_name in nightmares.keys():
		var nightmare_iter = nightmares[_nightmare_name]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)

	# Initialize world state
	if is_multiplayer:
		if multiplayer.is_server():
			# Server picks the starting world
			var normal_worlds = worlds.keys()
			if normal_worlds.size() > 0:
				current_world_name = normal_worlds[randi() % normal_worlds.size()]
			else:
				current_world_name = "world1"

			# Enable the starting world on server
			var starting_world = worlds[current_world_name]
			if starting_world:
				starting_world.visible = true
				_disable_interactions_in_world(starting_world, false)

				# FIX: Set environment on server too!
				if world_environment:
					if current_world_name in environments:
						world_environment.environment = environments[current_world_name]
					else:
						world_environment.environment = null

			# Sync world state to all clients
			sync_world_state.rpc(current_world_name)

			# Spawn host player (CRITICAL: Use RPC so clients see the host!)
			spawn_player.rpc(multiplayer.get_unique_id())  # FIX: Added .rpc() so clients see host!

			# Spawn any already-connected clients
			for peer_id in multiplayer.get_peers():
				spawn_player.rpc(peer_id)
	else:
		# Single player mode
		var normal_worlds = worlds.keys()
		if normal_worlds.size() > 0:
			current_world_name = normal_worlds[randi() % normal_worlds.size()]
		else:
			return

		var spawn_position = find_safe_spawn_position(current_world_name)

		# Enable the starting world
		var starting_world = worlds[current_world_name]
		if starting_world:
			starting_world.visible = true
			_disable_interactions_in_world(starting_world, false)

		teleport_to_world(current_world_name, spawn_position)
	
	# Initialize voice chat for multiplayer
	if is_multiplayer:
		# Use Godot's built-in microphone capture
		voice_sample_rate = 48000  # Standard high-quality sample rate
		print("Voice chat initialized - Sample rate: ", voice_sample_rate, "Hz")
		# Start voice recording automatically (always-on proximity chat)
		start_voice_recording()
		print("Proximity chat enabled (always-on)")
		print("")
		print("=== PROXIMITY CHAT TROUBLESHOOTING ===")
		print("If voice chat isn't working, check:")
		print("1. Windows Settings > Privacy > Microphone - Allow Godot")
		print("2. Steam > Settings > Voice - Test microphone")
		print("3. Make sure your microphone is not muted")
		print("4. Speak into your microphone to test")
		print("======================================")
		print("")

	# Initialize and start the main timer
	timer = Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.one_shot = false
	timer.timeout.connect(_on_timer_tick)
	add_child(timer)
	timer.start()
	
	# Initialize and start the world timer
	world_timer = Timer.new()
	world_timer.wait_time = 1.0
	world_timer.autostart = true
	world_timer.one_shot = false
	world_timer.timeout.connect(_on_world_timer_tick)
	add_child(world_timer)
	world_timer.start()
	
	# Set the timer label
	if timer_label:
		timer_label.text = str(time_left)
	
	# Ensure the transition_rect is initially hidden
	if transition_rect:
		transition_rect.visible = false

	# Create interaction UI elements
	_create_interaction_ui()

	# **Important: Mark this scene as the current main scene.**
	get_tree().set_current_scene(self)

func _disable_interactions_in_world(world: Node, disable: bool):
	for child in world.get_children():
		if child is Area3D:
			child.set_deferred("monitoring", !disable)
		elif child is CollisionObject3D:
			if disable:
				# Store original collision layers and masks if not already stored
				if not original_collision_layers.has(child.get_instance_id()):
					original_collision_layers[child.get_instance_id()] = child.collision_layer
				if not original_collision_masks.has(child.get_instance_id()):
					original_collision_masks[child.get_instance_id()] = child.collision_mask
				# Disable collisions by setting layers and masks to 0
				child.set_deferred("collision_layer", 0)
				child.set_deferred("collision_mask", 0)
			else:
				# Restore original collision layers and masks
				if original_collision_layers.has(child.get_instance_id()):
					child.set_deferred("collision_layer", original_collision_layers[child.get_instance_id()])
				if original_collision_masks.has(child.get_instance_id()):
					child.set_deferred("collision_mask", original_collision_masks[child.get_instance_id()])
		# NOTE: Removed AudioStreamPlayer pause/unpause logic
		# Audio volume is now controlled by the audio bus system (Music/SFX/Voices buses)
		# This allows the settings menu volume sliders to work correctly

		# Recursively disable interactions for child nodes
		if child.get_child_count() > 0:
			_disable_interactions_in_world(child, disable)

func _on_world_timer_tick():
	# Only server controls world transitions in multiplayer
	if is_multiplayer and not multiplayer.is_server():
		return

	time_in_world += 1.0
	if time_in_world >= time_before_nightmare:
		teleport_to_nightmare_world(current_world_name)
		time_in_world = 0.0

func teleport_to_nightmare_world(world_name: String):
	# Only server controls world transitions in multiplayer
	if is_multiplayer and not multiplayer.is_server():
		return

	var nightmare_world_name = ""
	if world_name.begins_with("world"):
		var world_number = world_name.substr(5)
		nightmare_world_name = "nightmare" + world_number
	else:
		return
	if nightmare_world_name in nightmares:
		# FIX: Don't teleport players, keep them in same position!
		# Just switch the world with a black fade
		teleport_to_world(nightmare_world_name, Vector3.ZERO, true)  # true = keep player positions

func teleport_to_random_world():
	# Only server controls world transitions in multiplayer
	if is_multiplayer and not multiplayer.is_server():
		return

	var rand_val = randi() % 100
	if rand_val < nightmare_chance:
		var available_nightmares = nightmares.keys()
		if available_nightmares.size() > 0:
			var random_nightmare = available_nightmares[randi() % available_nightmares.size()]
			var spawn_position = find_safe_spawn_position(random_nightmare)
			teleport_to_world(random_nightmare, spawn_position)
		else:
			teleport_to_random_normal_world()
	elif rand_val < nightmare_chance + world_chance:
		teleport_to_random_normal_world()

func teleport_to_random_normal_world():
	# Only server controls world transitions in multiplayer
	if is_multiplayer and not multiplayer.is_server():
		return

	var available_worlds = worlds.keys()
	available_worlds.erase(current_world_name)
	if available_worlds.size() > 0:
		var random_world = available_worlds[randi() % available_worlds.size()]
		var spawn_position = find_safe_spawn_position(random_world)
		teleport_to_world(random_world, spawn_position)

func teleport_to_world(world_name: String, spawn_position: Vector3, keep_player_positions: bool = false):
	is_transitioning = true
	play_transition_effect(Callable(self, "_do_teleport_to_world").bind(world_name, spawn_position, keep_player_positions))

func _do_teleport_to_world(world_name: String, spawn_position: Vector3, keep_player_positions: bool = false):
	for _world_name in worlds.keys():
		var world_iter = worlds[_world_name]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)
	for _nightmare_name in nightmares.keys():
		var nightmare_iter = nightmares[_nightmare_name]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)
	if world_name in worlds or world_name in nightmares:
		var target_world = worlds.get(world_name, nightmares.get(world_name, null))
		if target_world:
			target_world.visible = true
			_disable_interactions_in_world(target_world, false)
			print("Enabled interactions for world:", world_name)
			current_world_name = world_name
			time_in_world = 0.0

			# Assign the corresponding environment
			if world_environment:
				if world_name in environments:
					world_environment.environment = environments[world_name]
				else:
					world_environment.environment = null  # Or set a default environment

			# Sync world state to clients in multiplayer
			if is_multiplayer and multiplayer.is_server():
				print("SERVER: Syncing world change to clients: ", world_name)
				sync_world_state.rpc(world_name)

			# Teleport players (or keep their positions)
			if not keep_player_positions:
				# FIX: Give each player a UNIQUE spawn position!
				if is_multiplayer:
					# Teleport all multiplayer players to DIFFERENT positions
					for peer_id in players:
						var player = players[peer_id]
						if player:
							# Find a unique safe spawn position for each player
							var unique_spawn = find_safe_spawn_position(world_name, 50, 2.0)
							player.global_transform.origin = unique_spawn
							print("Teleported player ", peer_id, " to unique position: ", unique_spawn)
				else:
					# Teleport single-player player
					var player = get_node_or_null("SubViewportContainer/SubViewport/Player")
					if player:
						player.global_transform.origin = spawn_position
			else:
				# Keep player positions (for nightmare transitions)
				print("Keeping player positions during world transition")

func _on_area_3d_body_entered(_body: Node3D):
	# DISABLED: Old automatic teleportation on area trigger
	# Now using end_object interaction system instead
	pass

func _on_timer_tick():
	time_left -= 1
	if timer_label:
		timer_label.text = str(time_left)
	if time_left <= 0:
		go_to_main_menu()

func go_to_main_menu():
	if main_menu_scene:
		get_tree().change_scene_to_packed(main_menu_scene)
	else:
		print("Error: Main menu scene is not set.")

func _input(event):
	# Voice chat is now always-on, no push-to-talk needed
	# Open voice settings with F1
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		if voice_settings_ui:
			voice_settings_ui.show_settings()

func _process(delta):
	# Check for voice data continuously in multiplayer (always-on voice chat)
	if is_multiplayer:
		voice_send_timer += delta
		if voice_send_timer >= voice_send_interval:
			voice_send_timer = 0.0
			check_for_voice()

	# Update voice indicator timer
	if voice_indicator_timer > 0.0:
		voice_indicator_timer -= delta
		if voice_indicator_timer <= 0.0:
			hide_voice_indicator()

	# MULTIPLAYER: Only server updates nightmare value, then syncs to clients
	if is_multiplayer:
		if multiplayer.is_server():
			# Server: Check if ANY player is moving
			var any_player_moving = false
			for peer_id in players:
				var player = players[peer_id]
				if player and "is_moving" in player:
					if player.is_moving:
						any_player_moving = true
						break

			update_nightmare_and_dream_speed(any_player_moving)

			# Update nightmare value on server
			if nightmare_speed > 0:
				nightmare_value += nightmare_speed * delta * nightmare_increment
			elif dream_value > 0:
				nightmare_value -= dream_value * delta * dream_increment
			nightmare_value = clamp(nightmare_value, 0, 100)

			# OPTIMIZATION: Rate-limited sync - only send updates 5 times per second
			nightmare_sync_timer += delta
			if nightmare_sync_timer >= NIGHTMARE_SYNC_INTERVAL:
				nightmare_sync_timer = 0.0
				sync_nightmare_value.rpc(nightmare_value)

		# Update local UI (both server and clients)
		nightmare_bar.value = nightmare_value
		if nightmare_value >= 100:
			_trigger_jumpscare()
	else:
		# Single player: original logic
		if nightmare_speed > 0:
			nightmare_value += nightmare_speed * delta * nightmare_increment
		elif dream_value > 0:
			nightmare_value -= dream_value * delta * dream_increment
		nightmare_value = clamp(nightmare_value, 0, 100)
		nightmare_bar.value = nightmare_value
		if nightmare_value >= 100:
			_trigger_jumpscare()

func update_nightmare_and_dream_speed(is_moving: bool):
	if is_in_nightmare_world():
		nightmare_speed = 1.0
		dream_value = 0.0
	else:
		if is_moving:
			nightmare_speed = 0.0
			dream_value = 1.0
		else:
			nightmare_speed = 0.5
			dream_value = 0.0

func is_in_nightmare_world() -> bool:
	return current_world_name in nightmares

func _trigger_jumpscare():
	nightmare_value = 0.0
	nightmare_bar.value = nightmare_value
	# Because we've marked the current scene as main in _ready(), 
	# this will properly replace the current scene with the jumpscare scene.
	get_tree().change_scene_to_file("res://Jumpscare.tscn")



func find_spawn_near_player(player_pos: Vector3, attempts: int = 50) -> Vector3:
	# Try to spawn in a circle around the player
	var min_distance = 3.0  # At least 3 units away
	var max_distance = 8.0  # At most 8 units away

	for i in range(attempts):
		# Random angle around the player
		var angle = randf() * TAU  # TAU = 2*PI (full circle)
		var distance = randf_range(min_distance, max_distance)

		# Calculate position in a circle around the player
		var offset = Vector3(
			cos(angle) * distance,
			0,
			sin(angle) * distance
		)

		var pos = player_pos + offset

		# Adjust to ground level
		pos = adjust_position_to_ground(pos)

		# Check if safe (not inside walls, not on top of other players)
		if pos != null and is_position_safe(pos, 1.5):
			return pos

	# Fallback: just offset to the side
	return player_pos + Vector3(5, 0, 0)

func find_safe_spawn_position(world_name: String, attempts: int = 50, radius: float = 1.0) -> Vector3:
	for i in range(attempts):
		var pos = get_random_spawn_position(world_name)
		pos = adjust_position_to_ground(pos)
		if pos != null and is_position_safe(pos, radius):
			return pos
	return Vector3(0, 10, 0)  # Or some predefined safe position

func adjust_position_to_ground(pos: Vector3):
	var world = get_tree().root.get_world_3d()
	var space_state = world.direct_space_state
	var from_point = pos
	var to_point = pos - Vector3(0, 100, 0)

	var query = PhysicsRayQueryParameters3D.new()
	query.from = from_point
	query.to = to_point

	# Only exclude single-player player if it exists
	var single_player = get_node_or_null("SubViewportContainer/SubViewport/Player")
	if single_player:
		query.exclude = [ single_player ]

	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var result = space_state.intersect_ray(query)
	if result.size() > 0:
		var ground_y = result.position.y
		pos.y = ground_y + 1.0
		return pos
	else:
		return null

func is_position_safe(pos: Vector3, radius: float) -> bool:
	# Check if any existing players are too close
	# Minimum distance is 2.5 units to prevent spawning on top of each other
	var min_distance = max(radius * 2.0, 2.5)
	var min_distance_sq = min_distance * min_distance  # OPTIMIZATION: Pre-square for faster comparison

	for peer_id in players:
		var player = players[peer_id]
		if player:
			# OPTIMIZATION: Use distance_squared_to() - 4-5x faster than distance_to()
			var distance_sq = pos.distance_squared_to(player.global_position)
			if distance_sq < min_distance_sq:
				print("Position too close to player ", peer_id, " (distance: ", sqrt(distance_sq), ", min: ", min_distance, ")")
				return false

	var world = get_tree().root.get_world_3d()
	var space_state = world.direct_space_state

	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = radius
	var transform = Transform3D(Basis.IDENTITY, pos)

	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = sphere_shape
	query.transform = transform
	query.margin = 0.1

	# Only exclude single-player player if it exists
	var single_player = get_node_or_null("SubViewportContainer/SubViewport/Player")
	if single_player:
		query.exclude = [ single_player ]

	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var result = space_state.intersect_shape(query, 1)
	return result.size() == 0

func get_random_spawn_position(world_name: String) -> Vector3:
	if world_name.begins_with("world"):
		return get_random_spawn_position_in_world(world_name)
	elif world_name.begins_with("nightmare"):
		return get_random_spawn_position_in_nightmare(world_name)
	else:
		return Vector3.ZERO

func get_random_spawn_position_in_world(_world_name: String) -> Vector3:
	var min_x = -100
	var max_x = 100
	var min_y = 10.0
	var max_y = 50.0
	var min_z = -100
	var max_z = 100

	var random_x = randf_range(min_x, max_x)
	var random_y = randf_range(min_y, max_y)
	var random_z = randf_range(min_z, max_z)

	return Vector3(random_x, random_y, random_z)

func get_random_spawn_position_in_nightmare(_nightmare_name: String) -> Vector3:
	var min_x = -100
	var max_x = 100
	var min_y = 10.0
	var max_y = 50.0
	var min_z = -100
	var max_z = 100

	var random_x = randf_range(min_x, max_x)
	var random_y = randf_range(min_y, max_y)
	var random_z = randf_range(min_z, max_z)

	return Vector3(random_x, random_y, random_z)

func _on_area_3d_area_entered(_area: Area3D) -> void:
	pass

func play_transition_effect(completion_callback: Callable):
	if transition_rect:
		transition_rect.visible = true
		transition_rect.modulate.a = 0.0
		var tween = create_tween()
		tween.tween_property(transition_rect, "modulate:a", 1.0, 0.1)
		tween.tween_callback(completion_callback)
		tween.tween_property(transition_rect, "modulate:a", 0.0, 0.5)
		tween.tween_callback(Callable(self, "_hide_transition_rect"))

func _hide_transition_rect():
	if transition_rect:
		transition_rect.visible = false
	is_transitioning = false

# Multiplayer player spawning
func _on_player_connected(id: int) -> void:
	print("SERVER: Peer ", id, " connected to network (waiting for client_ready signal...)")

func _on_player_disconnected(id: int) -> void:
	if players.has(id):
		players[id].queue_free()
		players.erase(id)

func _on_connected_to_server() -> void:
	# Tell the server that this client is ready to receive world state
	client_ready.rpc_id(1)  # 1 is always the server ID

# Helper function to notify server when client world is ready
func _notify_server_ready() -> void:
	client_ready.rpc_id(1)  # 1 is always the server ID

# Client tells server it's ready to receive world state
@rpc("any_peer", "call_remote", "reliable")
func client_ready() -> void:
	var client_id = multiplayer.get_remote_sender_id()

	# Sync the current world state to the client
	sync_world_state.rpc_id(client_id, current_world_name)

	# Wait for world state to sync
	await get_tree().create_timer(0.5).timeout

	# Spawn the player for everyone
	spawn_player.rpc(client_id)

# Sync world state from server to clients
@rpc("authority", "call_remote", "reliable")
func sync_world_state(world_name: String) -> void:
	# Disable all worlds
	for _world_name in worlds.keys():
		var world_iter = worlds[_world_name]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)

	# Disable all nightmares
	for _nightmare_name in nightmares.keys():
		var nightmare_iter = nightmares[_nightmare_name]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)

	# Set current world
	current_world_name = world_name

	# Enable the synced world
	var target_world = worlds.get(world_name, nightmares.get(world_name, null))
	if target_world:
		target_world.visible = true
		_disable_interactions_in_world(target_world, false)

		# Set environment
		if world_environment:
			if world_name in environments:
				world_environment.environment = environments[world_name]
			else:
				world_environment.environment = null

@rpc("any_peer", "call_local", "reliable")
func spawn_player(peer_id: int) -> void:
	# Don't spawn if already exists
	if players.has(peer_id):
		return

	var player = multiplayer_player_scene.instantiate()
	player.name = str(peer_id)

	# Add to the viewport FIRST (before setting position)
	var viewport = $SubViewportContainer/SubViewport
	viewport.add_child(player)

	# Wait for node to be ready in the tree
	await get_tree().process_frame

	# Set up voice receiver for remote players with correct sample rate
	if peer_id != multiplayer.get_unique_id():
		if player.has_method("setup_voice_receiver"):
			player.setup_voice_receiver(voice_sample_rate)

	var spawn_pos: Vector3

	# If there are already players, spawn NEAR them (but not on top)
	if players.size() > 0:
		# Get the first player's position
		var first_player = players.values()[0]
		spawn_pos = find_spawn_near_player(first_player.global_position)
	else:
		# First player - spawn at random safe position
		spawn_pos = find_safe_spawn_position(current_world_name, 100, 2.0)

	player.global_position = spawn_pos

	# THEN add to players dictionary (so next spawn can check against this player)
	players[peer_id] = player

# ========== INTERACTION SYSTEM ==========

func _create_interaction_ui() -> void:
	# Create interaction label (centered at bottom of screen)
	interaction_label = Label.new()
	interaction_label.name = "InteractionLabel"
	interaction_label.text = ""
	interaction_label.visible = false
	interaction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	interaction_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# Position at bottom center
	interaction_label.anchor_left = 0.5
	interaction_label.anchor_right = 0.5
	interaction_label.anchor_top = 1.0
	interaction_label.anchor_bottom = 1.0
	interaction_label.offset_left = -150
	interaction_label.offset_right = 150
	interaction_label.offset_top = -80
	interaction_label.offset_bottom = -50
	interaction_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	interaction_label.grow_vertical = Control.GROW_DIRECTION_BEGIN

	# Add to CanvasLayer
	$CanvasLayer.add_child(interaction_label)

	# Create progress bar
	interaction_progress_bar = ProgressBar.new()
	interaction_progress_bar.name = "InteractionProgressBar"
	interaction_progress_bar.visible = false
	interaction_progress_bar.min_value = 0.0
	interaction_progress_bar.max_value = 1.0
	interaction_progress_bar.value = 0.0
	interaction_progress_bar.show_percentage = false

	# Position below the label
	interaction_progress_bar.anchor_left = 0.5
	interaction_progress_bar.anchor_right = 0.5
	interaction_progress_bar.anchor_top = 1.0
	interaction_progress_bar.anchor_bottom = 1.0
	interaction_progress_bar.offset_left = -100
	interaction_progress_bar.offset_right = 100
	interaction_progress_bar.offset_top = -45
	interaction_progress_bar.offset_bottom = -30
	interaction_progress_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	interaction_progress_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN

	# Add to CanvasLayer
	$CanvasLayer.add_child(interaction_progress_bar)

	# Create voice indicator (top left corner)
	voice_indicator = Label.new()
	voice_indicator.name = "VoiceIndicator"
	voice_indicator.text = ""
	voice_indicator.visible = false
	voice_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	voice_indicator.vertical_alignment = VERTICAL_ALIGNMENT_TOP

	# Position at top left
	voice_indicator.anchor_left = 0.0
	voice_indicator.anchor_right = 0.0
	voice_indicator.anchor_top = 0.0
	voice_indicator.anchor_bottom = 0.0
	voice_indicator.offset_left = 10
	voice_indicator.offset_right = 200
	voice_indicator.offset_top = 50
	voice_indicator.offset_bottom = 80

	# Style the label
	voice_indicator.add_theme_color_override("font_color", Color(0.2, 1.0, 0.2))  # Green color

	# Add to CanvasLayer
	$CanvasLayer.add_child(voice_indicator)

	# Create voice settings UI
	var voice_settings_scene = preload("res://voice_settings_ui.tscn")
	voice_settings_ui = voice_settings_scene.instantiate()
	$CanvasLayer.add_child(voice_settings_ui)

func show_interaction_prompt(text: String) -> void:
	if interaction_label:
		interaction_label.text = text
		interaction_label.visible = true

func hide_interaction_prompt() -> void:
	if interaction_label:
		interaction_label.visible = false
	if interaction_progress_bar:
		interaction_progress_bar.visible = false
		interaction_progress_bar.value = 0.0

func show_voice_indicator() -> void:
	"""Show the voice transmission indicator"""
	if voice_indicator:
		voice_indicator.text = "🎤 Speaking..."
		voice_indicator.visible = true
		voice_indicator_timer = 0.2  # Keep visible for 200ms after last voice packet

func hide_voice_indicator() -> void:
	"""Hide the voice transmission indicator"""
	if voice_indicator:
		voice_indicator.visible = false
		voice_indicator.text = ""

func update_interaction_progress(progress: float) -> void:
	if interaction_progress_bar:
		interaction_progress_bar.visible = true
		interaction_progress_bar.value = progress

# Get total player count (for end_object to check if all players are ready)
func get_total_player_count() -> int:
	if is_multiplayer:
		return players.size()
	else:
		return 1  # Single player

# Called by end_object when player activates it
@rpc("any_peer", "call_local", "reliable")
func teleport_from_end_object() -> void:
	# Only server handles the actual teleportation
	if is_multiplayer and not multiplayer.is_server():
		# Client sends request to server
		teleport_from_end_object.rpc_id(1)
		return

	# Teleport to a random NORMAL world (not nightmare)
	var available_worlds = worlds.keys()
	available_worlds.erase(current_world_name)  # Don't teleport to current world

	if available_worlds.size() > 0:
		var random_world = available_worlds[randi() % available_worlds.size()]

		# Teleport with random spawn positions (NOT keeping positions)
		var spawn_position = find_safe_spawn_position(random_world)
		teleport_to_world(random_world, spawn_position, false)

# ============================================================================
# VOICE CHAT FUNCTIONS
# ============================================================================

func get_nearby_peers() -> Array:
	"""Get peer IDs of players within voice range - OPTIMIZATION: Proximity-based voice chat"""
	var nearby = []

	if not is_multiplayer:
		return nearby

	var my_peer_id = multiplayer.get_unique_id()
	if not players.has(my_peer_id):
		return nearby

	var my_position = players[my_peer_id].global_position

	for peer_id in players:
		if peer_id == my_peer_id:
			continue  # Don't send to ourselves

		var other_player = players[peer_id]
		if not other_player:
			continue

		# OPTIMIZATION: Use distance_squared_to() - 4-5x faster than distance_to()
		var distance_sq = my_position.distance_squared_to(other_player.global_position)

		if distance_sq <= VOICE_HEAR_DISTANCE_SQ:
			nearby.append(peer_id)

	return nearby

func check_for_voice():
	"""Check for available voice data and send to network - called periodically"""
	if not mic_effect or not is_recording:
		return

	# Get available audio frames from microphone
	var frames_available = mic_effect.get_frames_available()

	if frames_available > 0:
		# Capture audio data (get at least 2400 frames = 50ms at 48kHz)
		var min_frames = int(voice_sample_rate * voice_send_interval)
		if frames_available >= min_frames:
			# Get the audio data
			var audio_data = mic_effect.get_buffer(min_frames)

			# OPTIMIZATION: Convert to MONO and use RMS-based VAD for better quality
			var pcm_data = PackedByteArray()
			pcm_data.resize(audio_data.size() * 2)  # 2 bytes per sample (mono = 50% bandwidth savings!)

			# Calculate RMS for Voice Activity Detection
			var sum_squares: float = 0.0
			const VAD_THRESHOLD = 0.003  # Lower threshold to pick up quieter sounds (was 0.01)

			# PERFORMANCE: Combined VAD + Mono conversion loop
			for i in range(audio_data.size()):
				var frame = audio_data[i]

				# Convert stereo to mono by averaging channels (50% bandwidth savings)
				var mono_sample = (frame.x + frame.y) * 0.5

				# Accumulate for RMS calculation
				sum_squares += mono_sample * mono_sample

				# Convert to 16-bit signed integer
				var sample_int = int(clamp(mono_sample, -1.0, 1.0) * 32767.0)

				# Convert signed to unsigned 16-bit for transmission
				var sample_unsigned = sample_int if sample_int >= 0 else sample_int + 65536

				# Write as little-endian 16-bit value (mono = 2 bytes instead of 4)
				var idx = i * 2
				pcm_data[idx] = sample_unsigned & 0xFF
				pcm_data[idx + 1] = (sample_unsigned >> 8) & 0xFF

			# Check RMS against threshold
			var rms = sqrt(sum_squares / audio_data.size())
			if rms < VAD_THRESHOLD:
				return  # Silent audio - don't transmit

			# Show voice indicator
			show_voice_indicator()

			# OPTIMIZATION: Proximity-based voice - only send to nearby players
			var nearby_peers = get_nearby_peers()
			if nearby_peers.size() == 0:
				return  # No one nearby to hear us - save bandwidth!

			# Send to each nearby peer individually (targeted RPC)
			for peer_id in nearby_peers:
				send_voice_packet.rpc_id(peer_id, pcm_data)

@rpc("any_peer", "unreliable_ordered", "call_remote")
func send_voice_packet(pcm_voice: PackedByteArray):
	"""Receive voice packet from network - OPTIMIZATION: unreliable_ordered prevents out-of-order packets"""
	var sender_id = multiplayer.get_remote_sender_id()

	# PERFORMANCE: Removed debug logging - was causing massive console spam
	# get_remote_sender_id() returns 0 if called locally
	if sender_id == 0:
		return

	# Don't process our own voice
	if sender_id == multiplayer.get_unique_id():
		return

	# Find the player who sent this voice data
	if players.has(sender_id):
		var player = players[sender_id]
		if player.has_method("receive_voice_data"):
			player.receive_voice_data(pcm_voice)

@rpc("authority", "unreliable", "call_remote")
func sync_nightmare_value(value: float):
	"""Sync nightmare bar value from server to clients"""
	nightmare_value = value
	nightmare_bar.value = value

func start_voice_recording():
	"""Start recording voice using Godot's microphone"""
	if not is_multiplayer:
		return

	print("=== INITIALIZING GODOT MICROPHONE ===")

	# Create AudioStreamPlayer for microphone input
	mic_player = AudioStreamPlayer.new()
	add_child(mic_player)

	# Set up microphone stream
	var mic_stream = AudioStreamMicrophone.new()
	mic_player.stream = mic_stream

	# Add AudioEffectCapture to capture the audio data
	var bus_idx = AudioServer.get_bus_index("Record")
	if bus_idx == -1:
		# Create a new bus for recording if it doesn't exist
		bus_idx = AudioServer.bus_count
		AudioServer.add_bus(bus_idx)
		AudioServer.set_bus_name(bus_idx, "Record")
		AudioServer.set_bus_mute(bus_idx, true)  # Mute so we don't hear ourselves

	# Add capture effect
	var capture_effect = AudioEffectCapture.new()
	capture_effect.buffer_length = 0.2  # PERFORMANCE: 200ms buffer for lower latency
	AudioServer.add_bus_effect(bus_idx, capture_effect)
	mic_effect = capture_effect

	# Route mic player to the Record bus
	mic_player.bus = "Record"

	# Start playing (this starts capturing microphone input)
	mic_player.play()

	is_recording = true
	print("✓ Microphone initialized successfully")
	print("  Sample rate: ", voice_sample_rate, " Hz")
	print("  Bus: Record (muted)")
	print("  Speak into your microphone to test...")
	print("===============================================")

func stop_voice_recording():
	"""Stop recording voice"""
	if not is_multiplayer:
		return

	is_recording = false

	if mic_player:
		mic_player.stop()
		mic_player.queue_free()
		mic_player = null

	mic_effect = null
	print("Voice recording stopped")

func load_audio_settings():
	"""Load and apply saved audio settings"""
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")

	# Audio bus indices
	const BUS_MASTER = 0
	const BUS_MUSIC = 1
	const BUS_SFX = 2
	const BUS_VOICES = 3

	if err == OK:
		var music_volume = config.get_value("audio", "music_volume", 100)
		var sfx_volume = config.get_value("audio", "sfx_volume", 100)
		var voices_volume = config.get_value("audio", "voices_volume", 100)

		set_bus_volume(BUS_MUSIC, music_volume)
		set_bus_volume(BUS_SFX, sfx_volume)
		set_bus_volume(BUS_VOICES, voices_volume)
	else:
		# Use defaults (100%)
		set_bus_volume(BUS_MUSIC, 100)
		set_bus_volume(BUS_SFX, 100)
		set_bus_volume(BUS_VOICES, 100)

func set_bus_volume(bus_index: int, volume_percent: float):
	"""Set audio bus volume from percentage (0-100)"""
	if volume_percent <= 0:
		AudioServer.set_bus_mute(bus_index, true)
	else:
		AudioServer.set_bus_mute(bus_index, false)
		# Convert percentage to decibels with logarithmic curve
		var normalized = volume_percent / 100.0
		var db = -40 + (40 * normalized * normalized)
		AudioServer.set_bus_volume_db(bus_index, db)
