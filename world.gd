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

# Voice chat
var is_recording: bool = false
var voice_sample_rate: int = 48000
var local_steam_id: int = 0
var voice_restart_cooldown: float = 0.0

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
	print("World _ready - is_multiplayer: ", is_multiplayer)

	# Debug viewport setup
	var viewport = $SubViewportContainer/SubViewport
	print("Viewport size: ", viewport.size)
	print("Viewport render mode: ", viewport.render_target_update_mode)
	print("Viewport handle_input_locally: ", viewport.handle_input_locally)

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
				print("Disabled single-player camera")

			# Remove it from the scene tree immediately
			old_player.get_parent().remove_child(old_player)
			old_player.queue_free()
			print("Removed single-player player node")

	# Disable all worlds initially
	for _world_name in worlds.keys():
		var world_iter = worlds[_world_name]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)
			print("Disabled interactions for world:", _world_name)

	# Disable all nightmares initially
	for _nightmare_name in nightmares.keys():
		var nightmare_iter = nightmares[_nightmare_name]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)
			print("Disabled interactions for nightmare:", _nightmare_name)

	# Initialize world state
	if is_multiplayer:
		if multiplayer.is_server():
			# Server picks the starting world
			var normal_worlds = worlds.keys()
			if normal_worlds.size() > 0:
				current_world_name = normal_worlds[randi() % normal_worlds.size()]
			else:
				current_world_name = "world1"

			print("SERVER: Selected starting world: ", current_world_name)

			# Enable the starting world on server
			var starting_world = worlds[current_world_name]
			if starting_world:
				starting_world.visible = true
				_disable_interactions_in_world(starting_world, false)
				print("SERVER: Enabled starting world: ", current_world_name)

				# FIX: Set environment on server too!
				if world_environment:
					if current_world_name in environments:
						world_environment.environment = environments[current_world_name]
						print("SERVER: Set environment for: ", current_world_name)
					else:
						world_environment.environment = null

			# Sync world state to all clients
			sync_world_state.rpc(current_world_name)

			# Spawn host player (CRITICAL: Use RPC so clients see the host!)
			print("SERVER: Spawning host player...")
			spawn_player.rpc(multiplayer.get_unique_id())  # FIX: Added .rpc() so clients see host!

			# Spawn any already-connected clients
			print("SERVER: Checking for already-connected clients...")
			for peer_id in multiplayer.get_peers():
				print("SERVER: Spawning client ", peer_id)
				spawn_player.rpc(peer_id)
		else:
			# Client waits for server to sync world state
			print("CLIENT: Waiting for server to sync world state...")
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
			print("Enabled interactions for starting world:", current_world_name)

		teleport_to_world(current_world_name, spawn_position)
	
	# Initialize voice chat for multiplayer
	if is_multiplayer:
		local_steam_id = Steam.getSteamID()
		# Use minimum 32kHz for decent quality (optimal rate is often 11025 Hz which sounds terrible)
		var optimal_rate = Steam.getVoiceOptimalSampleRate()
		voice_sample_rate = max(optimal_rate, 32000)  # Enforce minimum 32kHz quality
		print("Voice chat initialized - Optimal: ", optimal_rate, "Hz, Using: ", voice_sample_rate, "Hz")
		# Start voice recording automatically (always-on proximity chat)
		start_voice_recording()
		print("Proximity chat enabled (always-on)")
		print("")
		print("=== PROXIMITY CHAT TROUBLESHOOTING ===")
		print("If voice chat isn't working, check:")
		print("1. Windows Settings > Privacy > Microphone - Allow Steam")
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
	print("_disable_interactions_in_world called for:", world.name, "disable:", disable)
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
			print("Disabled interactions for world:", _world_name)
	for _nightmare_name in nightmares.keys():
		var nightmare_iter = nightmares[_nightmare_name]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)
			print("Disabled interactions for nightmare:", _nightmare_name)
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

func _on_area_3d_body_entered(body: Node3D):
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
	if event.is_action_pressed("ui_help") or (event is InputEventKey and event.pressed and event.keycode == KEY_F1):
		if voice_settings_ui:
			voice_settings_ui.show_settings()

func _process(delta):
	# Check for voice data continuously in multiplayer (always-on voice chat)
	if is_multiplayer:
		check_for_voice()

	# Update voice indicator timer
	if voice_indicator_timer > 0.0:
		voice_indicator_timer -= delta
		if voice_indicator_timer <= 0.0:
			hide_voice_indicator()

	# Update voice restart cooldown
	if voice_restart_cooldown > 0.0:
		voice_restart_cooldown -= delta

	# Update nightmare/dream values based on player movement
	if is_multiplayer:
		# Check if any local player is moving
		var local_player_moving = false
		for peer_id in players:
			var player = players[peer_id]
			if player and player.is_multiplayer_authority():
				# This is the local player
				# FIX: Check if the variable exists, not if it's a method
				if "is_moving" in player:
					local_player_moving = player.is_moving
				break
		update_nightmare_and_dream_speed(local_player_moving)

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
			print("Found safe spawn near player at distance: ", distance, " angle: ", rad_to_deg(angle))
			return pos

	print("Warning: Could not find spawn near player after ", attempts, " attempts. Using offset position.")
	# Fallback: just offset to the side
	return player_pos + Vector3(5, 0, 0)

func find_safe_spawn_position(world_name: String, attempts: int = 50, radius: float = 1.0) -> Vector3:
	for i in range(attempts):
		var pos = get_random_spawn_position(world_name)
		pos = adjust_position_to_ground(pos)
		if pos != null and is_position_safe(pos, radius):
			return pos
	print("Warning: Could not find a safe spawn position after", attempts, "attempts.")
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

	for peer_id in players:
		var player = players[peer_id]
		if player:
			var distance = pos.distance_to(player.global_position)
			if distance < min_distance:
				print("Position too close to player ", peer_id, " (distance: ", distance, ", min: ", min_distance, ")")
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

func get_random_spawn_position_in_world(world_name: String) -> Vector3:
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

func get_random_spawn_position_in_nightmare(nightmare_name: String) -> Vector3:
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

func _on_area_3d_area_entered(area: Area3D) -> void:
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
	print("Player disconnected: ", id)
	if players.has(id):
		players[id].queue_free()
		players.erase(id)

func _on_connected_to_server() -> void:
	print("Client connected to server! World scene loaded. Notifying server...")
	# Tell the server that this client is ready to receive world state
	client_ready.rpc_id(1)  # 1 is always the server ID

# Helper function to notify server when client world is ready
func _notify_server_ready() -> void:
	print("CLIENT: Sending client_ready to server...")
	client_ready.rpc_id(1)  # 1 is always the server ID

# Client tells server it's ready to receive world state
@rpc("any_peer", "call_remote", "reliable")
func client_ready() -> void:
	var client_id = multiplayer.get_remote_sender_id()
	print("SERVER: Client ", client_id, " is ready! Syncing world state...")

	# Sync the current world state to the client
	sync_world_state.rpc_id(client_id, current_world_name)

	# Wait for world state to sync
	await get_tree().create_timer(0.5).timeout

	print("SERVER: Spawning player for client ", client_id)
	# Spawn the player for everyone
	spawn_player.rpc(client_id)

# Sync world state from server to clients
@rpc("authority", "call_remote", "reliable")
func sync_world_state(world_name: String) -> void:
	print("CLIENT: Received world state sync - world: ", world_name)

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
		print("CLIENT: Enabled world: ", world_name)

		# Set environment
		if world_environment:
			if world_name in environments:
				world_environment.environment = environments[world_name]
			else:
				world_environment.environment = null
	else:
		print("CLIENT ERROR: Could not find world: ", world_name)

@rpc("any_peer", "call_local", "reliable")
func spawn_player(peer_id: int) -> void:
	print("spawn_player called for peer: ", peer_id)

	# Don't spawn if already exists
	if players.has(peer_id):
		print("Player ", peer_id, " already spawned!")
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
			print("Set up voice receiver for remote player ", peer_id, " with sample rate: ", voice_sample_rate)

	var spawn_pos: Vector3

	# If there are already players, spawn NEAR them (but not on top)
	if players.size() > 0:
		# Get the first player's position
		var first_player = players.values()[0]
		spawn_pos = find_spawn_near_player(first_player.global_position)
		print("Spawning player ", peer_id, " NEAR first player at: ", spawn_pos)
	else:
		# First player - spawn at random safe position
		spawn_pos = find_safe_spawn_position(current_world_name, 100, 2.0)
		print("Spawning FIRST player ", peer_id, " at: ", spawn_pos)

	player.global_position = spawn_pos

	# THEN add to players dictionary (so next spawn can check against this player)
	players[peer_id] = player

	print("Player ", peer_id, " spawned at: ", spawn_pos)
	print("Total players now: ", players.size())
	print("Viewport size: ", viewport.size)
	print("Viewport render mode: ", viewport.render_target_update_mode)

	# Wait for player to be ready and camera to be set up
	await get_tree().create_timer(0.2).timeout

	# Debug: List all cameras in viewport
	print("=== CAMERA DEBUG ===")
	for child in viewport.get_children():
		if child is CharacterBody3D:
			var cam = child.get_node_or_null("Camera3D")
			if cam:
				print("Found camera in ", child.name, " - Current: ", cam.current, " Position: ", cam.global_position)

	var active_cam = viewport.get_camera_3d()
	print("Viewport active camera: ", active_cam)
	print("=== END CAMERA DEBUG ===")

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

	print("Interaction UI created")
	print("Voice Settings UI created - Press F1 to open")

func show_interaction_prompt(text: String) -> void:
	if interaction_label:
		interaction_label.text = text
		interaction_label.visible = true
		print("Showing interaction prompt: ", text)

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

	print("Teleporting to random dream world from end object...")

	# Teleport to a random NORMAL world (not nightmare)
	var available_worlds = worlds.keys()
	available_worlds.erase(current_world_name)  # Don't teleport to current world

	if available_worlds.size() > 0:
		var random_world = available_worlds[randi() % available_worlds.size()]
		print("Selected random world: ", random_world)

		# Teleport with random spawn positions (NOT keeping positions)
		var spawn_position = find_safe_spawn_position(random_world)
		teleport_to_world(random_world, spawn_position, false)
	else:
		print("ERROR: No other worlds available to teleport to!")

# ============================================================================
# VOICE CHAT FUNCTIONS
# ============================================================================

func check_for_voice():
	"""Check for available voice data and send to network"""
	# Get voice data from Steam
	var voice_data: Dictionary = Steam.getVoice()

	# Debug: Print voice data status occasionally (every 120 frames = ~2 seconds)
	if Engine.get_process_frames() % 120 == 0:
		var result = voice_data.get('result', 'N/A')
		var written = voice_data.get('written', 'N/A')
		print("Voice check - Result: ", result, " Written: ", written)

		# Result codes: 1 = OK, 2 = NotRecording, 3 = NoData, 4 = BufferTooSmall, etc.
		if result == 2 and voice_restart_cooldown <= 0.0:
			print("WARNING: Steam Voice is not recording! Restarting voice recording...")
			# Try to restart voice recording
			Steam.stopVoiceRecording()
			await get_tree().create_timer(0.1).timeout
			Steam.startVoiceRecording()
			voice_restart_cooldown = 5.0  # Don't retry for 5 seconds
		elif result == 3:
			# NoData is normal when not speaking - no action needed
			pass
		elif result != 1:
			print("WARNING: Unexpected voice result code: ", result)

	# Send voice data if available
	if voice_data.has('result') and voice_data['result'] == 1 and voice_data.has('written') and voice_data['written'] > 0:
		print("Sending voice packet - Size: ", voice_data['written'])
		# Show voice indicator
		show_voice_indicator()
		# Send voice packet to all other peers (unreliable for low latency)
		send_voice_packet.rpc(voice_data['buffer'])

@rpc("any_peer", "unreliable", "call_remote")
func send_voice_packet(compressed_voice: PackedByteArray):
	"""Receive voice packet from network and decompress"""
	var sender_id = multiplayer.get_remote_sender_id()
	print("Received voice packet from peer: ", sender_id, " Size: ", compressed_voice.size())

	# Don't process our own voice
	if sender_id == multiplayer.get_unique_id():
		return

	# Decompress voice data
	var decompressed: Dictionary = Steam.decompressVoice(compressed_voice, voice_sample_rate)
	print("Decompressed voice - Result: ", decompressed.get('result', 'N/A'),
		  " Size: ", decompressed.get('size', 'N/A'))

	if decompressed.has('result') and decompressed['result'] == 1 and decompressed.has('size') and decompressed['size'] > 0:
		# Find the player who sent this voice data
		if players.has(sender_id):
			var player = players[sender_id]
			if player.has_method("receive_voice_data"):
				print("Sending voice data to player ", sender_id)
				player.receive_voice_data(decompressed['uncompressed'])
		else:
			print("WARNING: No player found for sender_id: ", sender_id)

func start_voice_recording():
	"""Start recording voice (call when always-on voice chat enabled)"""
	if not is_multiplayer:
		return

	is_recording = true
	Steam.startVoiceRecording()
	Steam.setInGameVoiceSpeaking(local_steam_id, true)
	print("Voice recording started - Steam ID: ", local_steam_id, " Sample rate: ", voice_sample_rate)

func stop_voice_recording():
	"""Stop recording voice (call when push-to-talk released)"""
	if not is_multiplayer:
		return

	is_recording = false
	Steam.stopVoiceRecording()
	Steam.setInGameVoiceSpeaking(local_steam_id, false)
	print("Voice recording stopped")

func load_audio_settings():
	"""Load and apply saved audio settings"""
	print("=== LOADING AUDIO SETTINGS ===")
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")

	# Audio bus indices
	const BUS_MASTER = 0
	const BUS_MUSIC = 1
	const BUS_SFX = 2
	const BUS_VOICES = 3

	print("Config load result: ", err, " (OK=", OK, ")")

	if err == OK:
		var music_volume = config.get_value("audio", "music_volume", 100)
		var sfx_volume = config.get_value("audio", "sfx_volume", 100)
		var voices_volume = config.get_value("audio", "voices_volume", 100)

		print("Loaded values - Music: ", music_volume, "% SFX: ", sfx_volume, "% Voices: ", voices_volume, "%")

		set_bus_volume(BUS_MUSIC, music_volume)
		set_bus_volume(BUS_SFX, sfx_volume)
		set_bus_volume(BUS_VOICES, voices_volume)

		print("Audio settings applied!")
	else:
		# Use defaults (100%)
		print("No saved settings found, using defaults (100%)")
		set_bus_volume(BUS_MUSIC, 100)
		set_bus_volume(BUS_SFX, 100)
		set_bus_volume(BUS_VOICES, 100)

func set_bus_volume(bus_index: int, volume_percent: float):
	"""Set audio bus volume from percentage (0-100)"""
	var bus_name = AudioServer.get_bus_name(bus_index)
	print("Setting bus ", bus_index, " (", bus_name, ") to ", volume_percent, "%")

	if volume_percent <= 0:
		AudioServer.set_bus_mute(bus_index, true)
		print("  -> MUTED bus ", bus_index, " (", bus_name, ")")
	else:
		AudioServer.set_bus_mute(bus_index, false)
		# Convert percentage to decibels with logarithmic curve
		var normalized = volume_percent / 100.0
		var db = -40 + (40 * normalized * normalized)
		AudioServer.set_bus_volume_db(bus_index, db)
		print("  -> Set bus ", bus_index, " (", bus_name, ") to ", db, " dB")
