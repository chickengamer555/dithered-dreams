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
var multiplayer_player_scene = preload("res://scenes/multiplayer_player.tscn")
var players = {}  # Dictionary to store player nodes by peer ID
var dead_players = {}  # Dictionary to track dead players by peer ID
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

@onready var nightmare_bar = $CanvasLayer/NightmareBar
@onready var sprint_bar = $CanvasLayer/SprintBar
@onready var transition_rect = $CanvasLayer/ColorRect  # Reference to the ColorRect for transitions

# Interaction UI (will be created dynamically)
var interaction_label: Label = null
var interaction_progress_bar: ProgressBar = null

# Voice chat UI
var voice_indicator: Label = null
var voice_indicator_timer: float = 0.0

# Settings menu UI
var settings_menu_instance: Control = null

# Dev terminal UI
var dev_terminal_instance: Control = null

@export var play_time: int = 300
var time_left: int = play_time
var timer: Timer

# REMOVED: world_timer and time_in_world - no longer using time-based nightmare transitions

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

	# Load audio settings for both single player and multiplayer
	# This ensures volume sliders work correctly regardless of mode
	load_audio_settings()

	# This is now a multiplayer-only game
	is_multiplayer = multiplayer.has_multiplayer_peer()

	if not is_multiplayer:
		print("ERROR: This game requires multiplayer! Please use Host or Join from main menu.")
		go_to_main_menu()
		return

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

	# Initialize voice chat (always runs since this is multiplayer-only)
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

	# REMOVED: world_timer - no longer using time-based nightmare transitions

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
		elif child is AudioStreamPlayer:
			# Control music playback when switching worlds
			if disable:
				# Stop music when world is disabled
				if child.playing:
					child.stop()
			else:
				# Start music when world is enabled (if autoplay is true)
				if child.autoplay and not child.playing:
					child.play()

		# Recursively disable interactions for child nodes
		if child.get_child_count() > 0:
			_disable_interactions_in_world(child, disable)

	# REMOVED: _on_world_timer_tick and teleport_to_nightmare_world
	# No longer using time-based nightmare transitions

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

func teleport_to_world(world_name: String, spawn_position: Vector3, keep_player_positions: bool = false, reset_nightmare: float = -1.0):
	is_transitioning = true
	play_transition_effect(Callable(self, "_do_teleport_to_world").bind(world_name, spawn_position, keep_player_positions, reset_nightmare))

func _do_teleport_to_world(world_name: String, spawn_position: Vector3, keep_player_positions: bool = false, reset_nightmare: float = -1.0):
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
			# REMOVED: time_in_world reset - no longer using time-based transitions

			# Reset nightmare value if requested (after world change)
			if reset_nightmare >= 0.0:
				nightmare_value = reset_nightmare
				nightmare_bar.value = nightmare_value
				print("Nightmare value reset to: ", nightmare_value, "%")

				# Sync to clients in multiplayer
				if is_multiplayer and multiplayer.is_server():
					sync_nightmare_value.rpc(nightmare_value)

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
				if is_multiplayer:
					# Spawn all players together near the host
					# First, find a random safe spawn position for the host
					var host_spawn = find_safe_spawn_position(world_name, 100, 2.0)

					# Get host player (server/first player)
					var host_id = 1 if multiplayer.is_server() else multiplayer.get_unique_id()
					var host_player = players.get(host_id)

					# If host exists, teleport them first
					if host_player and is_instance_valid(host_player):
						host_player.global_transform.origin = host_spawn
						print("Teleported host player ", host_id, " to random position: ", host_spawn)
					else:
						print("WARNING: Host player not found during world transition!")

					# Then spawn all other players near the host
					for peer_id in players:
						if peer_id == host_id:
							continue  # Skip host, already spawned

						var player = players[peer_id]
						if player and is_instance_valid(player):
							# Spawn near the host's position (3-8 units away)
							var nearby_spawn = find_spawn_near_player(host_spawn)
							player.global_transform.origin = nearby_spawn
							print("Teleported player ", peer_id, " near host at position: ", nearby_spawn)
				else:
					# Single player - just teleport to spawn position
					for peer_id in players:
						var player = players[peer_id]
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
	if time_left <= 0:
		go_to_main_menu()

func go_to_main_menu():
	if get_tree():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func leave_game():
	"""Properly disconnect from multiplayer and return to main menu"""
	print("[World] Player leaving game...")

	# Close settings menu if open
	if settings_menu_instance:
		settings_menu_instance.queue_free()
		settings_menu_instance = null

	# If in multiplayer, properly disconnect
	if is_multiplayer:
		var my_peer_id = multiplayer.get_unique_id()
		print("[World] Disconnecting peer ", my_peer_id)

		# CRITICAL: Notify all other clients to remove this player BEFORE disconnecting
		# This ensures the player is removed even if peer_disconnected doesn't fire properly
		notify_player_leaving.rpc(my_peer_id)

		# IMPORTANT: Remove our player locally first
		if players.has(my_peer_id):
			var player = players[my_peer_id]
			if player and is_instance_valid(player):
				player.queue_free()
			players.erase(my_peer_id)

		# Remove from dead players if we were dead
		if dead_players.has(my_peer_id):
			dead_players.erase(my_peer_id)

		# Give a moment for the RPC to send
		await get_tree().create_timer(0.1).timeout

		# Disconnect from multiplayer peer
		# This should also trigger peer_disconnected signal on other clients
		if multiplayer.multiplayer_peer:
			print("[World] Closing multiplayer peer connection...")
			multiplayer.multiplayer_peer.close()
			multiplayer.multiplayer_peer = null
			print("[World] Multiplayer peer closed")

	# Return to main menu
	go_to_main_menu()

func _input(event):
	# Voice chat is now always-on, no push-to-talk needed
	# Voice settings removed (F1 key no longer used)

	# Handle ESC key - close dev terminal if open, otherwise toggle settings
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if dev_terminal_instance and dev_terminal_instance.visible:
			# Close dev terminal with ESC
			close_dev_terminal()
			get_viewport().set_input_as_handled()
			return
		else:
			# Open/close settings menu with ESC (only if terminal not open)
			toggle_settings_menu()
		return

	# Open dev terminal with T key (only if not already open)
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		if not dev_terminal_instance or not dev_terminal_instance.visible:
			open_dev_terminal()
			get_viewport().set_input_as_handled()
		return

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

	# Update spectator camera position if spectating
	if has_meta("spectator_camera") and has_meta("spectator_target_id"):
		var spectator_camera = get_meta("spectator_camera")
		var target_id = get_meta("spectator_target_id")

		if spectator_camera and is_instance_valid(spectator_camera) and players.has(target_id):
			var target_player = players[target_id]
			if target_player and is_instance_valid(target_player):
				# Position camera behind and above the target player
				var offset = Vector3(0, 3, 5)
				# Rotate offset based on player's rotation
				var player_basis = target_player.global_transform.basis
				var rotated_offset = player_basis * offset

				spectator_camera.global_position = target_player.global_position + rotated_offset
				spectator_camera.look_at(target_player.global_position + Vector3(0, 1, 0))

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
			# NEW: In nightmare worlds, keep nightmare at 100%
			if is_in_nightmare_world():
				nightmare_value = 100.0
			else:
				# In dream worlds, nightmare slowly increases
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
		if nightmare_value >= 100 and not is_in_nightmare_world():
			_trigger_jumpscare()
	else:
		# SINGLE PLAYER: Update nightmare/dream speeds based on player movement
		var single_player = get_node_or_null("SubViewportContainer/SubViewport/Player")
		var is_player_moving = false
		if single_player and "is_moving" in single_player:
			is_player_moving = single_player.is_moving

		update_nightmare_and_dream_speed(is_player_moving)

		# In nightmare worlds, nightmare doesn't change (stays where it is)
		# In dream worlds, nightmare slowly increases
		if not is_in_nightmare_world():
			if nightmare_speed > 0:
				nightmare_value += nightmare_speed * delta * nightmare_increment
			elif dream_value > 0:
				nightmare_value -= dream_value * delta * dream_increment
			nightmare_value = clamp(nightmare_value, 0, 100)

		nightmare_bar.value = nightmare_value
		if nightmare_value >= 100 and not is_in_nightmare_world():
			_trigger_jumpscare()

func update_nightmare_and_dream_speed(is_moving: bool):
	# NEW GAMEPLAY: In nightmare world, nightmare stays at 100%
	# In dream world, nightmare slowly ticks up regardless of movement
	if is_in_nightmare_world():
		nightmare_speed = 0.0  # Don't increase in nightmare
		dream_value = 0.0
	else:
		# In dream worlds, nightmare always slowly increases
		nightmare_speed = 0.3  # Slow constant increase
		dream_value = 0.0

func update_sprint_meter(stamina_value: float):
	"""Update the sprint meter UI with the current stamina value"""
	if sprint_bar:
		sprint_bar.value = stamina_value

func is_in_nightmare_world() -> bool:
	return current_world_name in nightmares

func _trigger_jumpscare():
	# NEW GAMEPLAY: At 100% nightmare, teleport to nightmare version of current world
	# Keep nightmare at 100% (don't reset to 0)

	# Only trigger if we're NOT already in a nightmare world
	if not is_in_nightmare_world():
		# Find the nightmare version of the current world
		var nightmare_world_name = ""
		if current_world_name.begins_with("world"):
			var world_number = current_world_name.substr(5)
			nightmare_world_name = "nightmare" + world_number

			if nightmare_world_name in nightmares:
				# Teleport to nightmare world, keeping player positions
				teleport_to_world(nightmare_world_name, Vector3.ZERO, true)

func _player_killed(player: Node3D):
	"""Called when a lethal chaser kills a player"""
	if not player or not is_instance_valid(player):
		print("[World] _player_killed called with invalid player")
		return

	print("[World] Player killed: ", player.name)

	# In multiplayer, only server handles death
	if is_multiplayer and not multiplayer.is_server():
		return

	# Get the peer ID from the player node name
	var peer_id = int(player.name)

	# Mark player as dead
	dead_players[peer_id] = player



	# Check if any other players are still alive
	var alive_players = []
	for p_id in players:
		if not dead_players.has(p_id):
			alive_players.append(p_id)

	if alive_players.size() > 0:
		# There are alive players - make dead player spectate
		print("[World] Player ", peer_id, " will spectate. Alive players: ", alive_players)

		# Tell the dead player to spectate a random alive player
		var spectate_target_id = alive_players[randi() % alive_players.size()]

		if peer_id == multiplayer.get_unique_id():
			# If it's the local player (host), call locally
			start_spectating(spectate_target_id)
		else:
			# If it's a remote player, call via RPC
			start_spectating.rpc_id(peer_id, spectate_target_id)
	else:
		# No alive players - everyone is dead, go to main menu
		print("[World] All players dead! Going to main menu...")

		# Trigger jumpscare for all players, then go to main menu
		all_players_dead_go_to_menu.rpc()

		# Also trigger for server/host
		go_to_jumpscare_then_menu()

@rpc("authority", "call_remote", "reliable")


func start_spectating(target_peer_id: int):
	"""Make this player spectate another player in 3rd person"""
	print("[World] Starting 3rd person spectate mode for peer ", target_peer_id)

	# Disable local player's camera and input
	var local_player_id = multiplayer.get_unique_id()
	if players.has(local_player_id):
		var local_player = players[local_player_id]
		if local_player.has_method("disable_controls"):
			local_player.disable_controls()

		# Disable local player's first-person camera
		var local_camera = local_player.get_node_or_null("Camera3D")
		if local_camera:
			local_camera.current = false

	# Create a 3rd person spectator camera
	if players.has(target_peer_id):
		var target_player = players[target_peer_id]

		# Create a new camera for spectating
		var spectator_camera = Camera3D.new()
		spectator_camera.name = "SpectatorCamera"
		add_child(spectator_camera)

		# Position camera behind and above the target player
		spectator_camera.global_position = target_player.global_position + Vector3(0, 3, 5)
		spectator_camera.look_at(target_player.global_position + Vector3(0, 1, 0))
		spectator_camera.current = true
		spectator_camera.make_current()

		# Store reference to update camera position each frame
		set_meta("spectator_camera", spectator_camera)
		set_meta("spectator_target_id", target_peer_id)

		print("[World] Now spectating player ", target_peer_id, " in 3rd person")

@rpc("authority", "call_local", "reliable")
func all_players_dead_go_to_menu():
	"""All players are dead - trigger jumpscare then go to main menu"""
	print("[World] All players dead! Going to jumpscare then menu...")
	go_to_jumpscare_then_menu()

func go_to_jumpscare_then_menu():
	"""Transition to jumpscare scene, then to main menu"""
	if get_tree():
		get_tree().change_scene_to_file("res://scenes/Jumpscare.tscn")

func trigger_nonlethal_jumpscare():
	"""Trigger jumpscare overlay that stays in game (for non-lethal chaser)"""
	print("[World] Triggering non-lethal jumpscare overlay...")

	# Load and instantiate the jumpscare scene as an overlay
	var jumpscare_scene = load("res://scenes/Jumpscare.tscn")
	if jumpscare_scene:
		var jumpscare_instance = jumpscare_scene.instantiate()
		jumpscare_instance.is_overlay = true  # Mark as overlay so it removes itself instead of changing scenes

		# Add to the world as a child so it overlays on top of everything
		add_child(jumpscare_instance)

		print("[World] Jumpscare overlay added to world")

func find_spawn_near_player(player_pos: Vector3, attempts: int = 50) -> Vector3:
	# Try to spawn in a circle around the player
	var min_distance = 3.0  # At least 3 units away
	var max_distance = 8.0  # At most 8.0 units away

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

		# CRITICAL FIX: Keep the same Y level as the player (they're already on the ground)
		# Don't use adjust_position_to_ground() - physics isn't ready during spawn
		pos.y = player_pos.y

		# Check if safe (not inside walls, not on top of other players)
		if is_position_safe(pos, 1.5):
			print("✓ SPAWN NEAR: Found position ", distance, " units from host at: ", pos)
			return pos

	# Fallback: just offset to the side at same Y level
	var fallback = player_pos + Vector3(5, 0, 0)
	print("⚠ SPAWN NEAR: Using fallback position at: ", fallback)
	return fallback

func find_safe_spawn_position(world_name: String, attempts: int = 50, radius: float = 1.0) -> Vector3:
	"""
	Find a safe spawn position for a player.
	Priority:
	1. Use PlayerSpawnPoint nodes if available
	2. Fallback to (0, 10, 0) if no spawn points
	"""

	# PRIORITY 1: Try to use PlayerSpawnPoint nodes
	var spawn_points = get_player_spawn_points(world_name)
	if spawn_points.size() > 0:
		# Pick a random spawn point
		var random_index = randi() % spawn_points.size()
		var spawn_point = spawn_points[random_index]
		var pos = spawn_point.global_position
		print("✓ SPAWN: Using PlayerSpawnPoint at: ", pos)
		return pos

	# PRIORITY 2: No spawn points found, use fallback position
	print("⚠ No PlayerSpawnPoints found in '", world_name, "', using fallback position (0, 10, 0)")
	return Vector3(0, 10, 0)

func adjust_position_to_ground(pos: Vector3):
	"""
	Raycast down from the given position to find the actual ground level.
	This is needed because navmesh Y coordinates may not match the actual walkable ground.
	"""
	var world = get_tree().root.get_world_3d()
	var space_state = world.direct_space_state

	# Raycast from above the position down to find ground
	var from_point = pos + Vector3(0, 50, 0)  # Start 50 units above
	var to_point = pos - Vector3(0, 150, 0)   # Go 150 units below

	var query = PhysicsRayQueryParameters3D.new()
	query.from = from_point
	query.to = to_point

	# Only collide with static bodies (ground), not areas or other players
	query.collision_mask = 1  # Layer 1 is typically static geometry
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var result = space_state.intersect_ray(query)
	if result.size() > 0:
		var ground_y = result.position.y
		var adjusted_pos = Vector3(pos.x, ground_y + 1.0, pos.z)  # 1 unit above ground
		print("  🎯 Raycast hit ground at Y=", ground_y, ", adjusted to Y=", adjusted_pos.y)
		return adjusted_pos
	else:
		print("  ❌ Raycast found no ground between Y=", from_point.y, " and Y=", to_point.y)
		return null

func is_position_safe(pos: Vector3, radius: float) -> bool:
	# Check if any existing players are too close
	# Minimum distance is 2.5 units to prevent spawning on top of each other
	var min_distance = max(radius * 2.0, 2.5)
	var min_distance_sq = min_distance * min_distance  # OPTIMIZATION: Pre-square for faster comparison

	for peer_id in players:
		var player = players[peer_id]
		if player and is_instance_valid(player):
			# OPTIMIZATION: Use distance_squared_to() - 4-5x faster than distance_to()
			var distance_sq = pos.distance_squared_to(player.global_position)
			if distance_sq < min_distance_sq:
				print("  ✗ Position unsafe: Too close to player ", peer_id, " (distance: ", sqrt(distance_sq), ")")
				return false

	# CRITICAL FIX: Skip physics collision check during initial spawn
	# Physics bodies aren't ready yet, and navmesh already ensures walkable surfaces
	# We'll rely on the navmesh being correct and player distance checks

	# NOTE: If you want obstacle checking AFTER spawn, use this in a separate function
	# that's called after physics is ready (e.g., after await get_tree().physics_frame)

	return true

func get_random_spawn_position(world_name: String) -> Vector3:
	if world_name.begins_with("world"):
		return get_random_spawn_position_in_world(world_name)
	elif world_name.begins_with("nightmare"):
		return get_random_spawn_position_in_nightmare(world_name)
	else:
		return Vector3.ZERO

func get_random_spawn_position_in_world(world_name: String) -> Vector3:
	# Try to get a random position on the navigation mesh first
	var navmesh_pos = get_random_position_on_navmesh(world_name)
	if navmesh_pos != Vector3.ZERO:
		return navmesh_pos

	# Fallback to random position in bounds if navmesh not available
	print("⚠ WARNING: Using fallback random bounds for '", world_name, "' (navmesh failed)")
	var min_x = -100
	var max_x = 100
	var min_y = 10.0
	var max_y = 50.0
	var min_z = -100
	var max_z = 100

	var random_x = randf_range(min_x, max_x)
	var random_y = randf_range(min_y, max_y)
	var random_z = randf_range(min_z, max_z)

	var fallback_pos = Vector3(random_x, random_y, random_z)
	print("  Fallback position: ", fallback_pos)
	return fallback_pos

func get_random_spawn_position_in_nightmare(nightmare_name: String) -> Vector3:
	# Try to get a random position on the navigation mesh first
	var navmesh_pos = get_random_position_on_navmesh(nightmare_name)
	if navmesh_pos != Vector3.ZERO:
		return navmesh_pos

	# Fallback to random position in bounds if navmesh not available
	print("⚠ WARNING: Using fallback random bounds for '", nightmare_name, "' (navmesh failed)")
	var min_x = -100
	var max_x = 100
	var min_y = 10.0
	var max_y = 50.0
	var min_z = -100
	var max_z = 100

	var random_x = randf_range(min_x, max_x)
	var random_y = randf_range(min_y, max_y)
	var random_z = randf_range(min_z, max_z)

	var fallback_pos = Vector3(random_x, random_y, random_z)
	print("  Fallback position: ", fallback_pos)
	return fallback_pos

func get_random_position_on_navmesh(world_name: String) -> Vector3:
	"""
	Get a truly random position on the navigation mesh for the given world.
	This ensures players spawn on walkable surfaces anywhere in the level.
	"""
	# Get the world node
	var world_node = null
	if world_name in worlds:
		world_node = worlds[world_name]
	elif world_name in nightmares:
		world_node = nightmares[world_name]

	if not world_node:
		print(">>> NAVMESH ERROR: World '", world_name, "' not found")
		return Vector3.ZERO

	# Find NavigationRegion3D in the world
	var nav_region = find_navigation_region(world_node)
	if not nav_region:
		print(">>> NAVMESH ERROR: No NavigationRegion3D in '", world_name, "'")
		return Vector3.ZERO

	# Get the navigation mesh data
	var nav_mesh = nav_region.navigation_mesh
	if not nav_mesh:
		print(">>> NAVMESH ERROR: NavigationRegion3D has no navigation_mesh in '", world_name, "'")
		return Vector3.ZERO

	# Get all vertices from the navigation mesh
	var vertices = nav_mesh.get_vertices()
	if vertices.size() == 0:
		print(">>> NAVMESH ERROR: Navigation mesh has no vertices in '", world_name, "'")
		return Vector3.ZERO

	# Get the navigation map RID for validation
	var nav_map = nav_region.get_navigation_map()
	if not nav_map or not nav_map.is_valid():
		print(">>> NAVMESH ERROR: Navigation map not valid in '", world_name, "'")
		return Vector3.ZERO

	# Calculate the bounding box of the navmesh to understand its actual size
	var min_bounds = vertices[0]
	var max_bounds = vertices[0]
	for vertex in vertices:
		min_bounds.x = min(min_bounds.x, vertex.x)
		min_bounds.y = min(min_bounds.y, vertex.y)
		min_bounds.z = min(min_bounds.z, vertex.z)
		max_bounds.x = max(max_bounds.x, vertex.x)
		max_bounds.y = max(max_bounds.y, vertex.y)
		max_bounds.z = max(max_bounds.z, vertex.z)

	# Transform bounds to world space
	var world_transform = nav_region.global_transform
	var local_min = min_bounds
	var local_max = max_bounds
	min_bounds = world_transform * min_bounds
	max_bounds = world_transform * max_bounds

	print("🔍 DEBUG NAVMESH TRANSFORM for '", world_name, "':")
	print("  Local bounds: ", local_min, " to ", local_max)
	print("  World bounds: ", min_bounds, " to ", max_bounds)
	print("  Global transform scale: ", world_transform.basis.get_scale())

	# Try multiple random attempts within the actual navmesh bounds
	var max_attempts = 200
	var valid_positions = []

	for i in range(max_attempts):
		# Generate a random position within the navmesh bounding box
		var random_pos = Vector3(
			randf_range(min_bounds.x, max_bounds.x),
			randf_range(min_bounds.y, max_bounds.y),
			randf_range(min_bounds.z, max_bounds.z)
		)

		# Use NavigationServer3D to find the closest point on the navmesh
		var closest_point = NavigationServer3D.map_get_closest_point(nav_map, random_pos)

		# Check if the point is actually on the navmesh (close to our random point)
		var distance_to_navmesh = random_pos.distance_to(closest_point)

		# If we found a point close to the navmesh, it's valid
		if distance_to_navmesh < 150.0:  # Increased tolerance for scaled worlds
			valid_positions.append(closest_point)

	# If we found valid positions, pick a random one
	if valid_positions.size() > 0:
		# Use randi() to get a random index
		var random_index = randi() % valid_positions.size()
		var chosen_pos = valid_positions[random_index]
		print("✓ NAVMESH: Found ", valid_positions.size(), " valid positions in '", world_name, "', chose: ", chosen_pos)
		return chosen_pos

	print("✗ NAVMESH ERROR: Could not find any valid navmesh position in '", world_name, "' after ", max_attempts, " attempts")
	print("  Navmesh bounds: ", min_bounds, " to ", max_bounds)
	return Vector3.ZERO

func find_navigation_region(node: Node) -> NavigationRegion3D:
	"""Recursively search for a NavigationRegion3D in the given node tree"""
	if node is NavigationRegion3D:
		return node as NavigationRegion3D

	for child in node.get_children():
		var result = find_navigation_region(child)
		if result:
			return result

	return null

func get_player_spawn_points(world_name: String) -> Array:
	"""
	Get all PlayerSpawnPoint nodes in the specified world.
	Returns an array of PlayerSpawnPoint nodes.
	"""
	var spawn_points = []

	# Get the world node
	var world_node = null
	if world_name in worlds:
		world_node = worlds[world_name]
	elif world_name in nightmares:
		world_node = nightmares[world_name]

	if not world_node:
		print(">>> ERROR: World '", world_name, "' not found for spawn points")
		return spawn_points

	# Recursively find all PlayerSpawnPoint nodes
	spawn_points = find_player_spawn_points_recursive(world_node)

	print("🎯 Found ", spawn_points.size(), " PlayerSpawnPoint(s) in '", world_name, "'")
	return spawn_points

func find_player_spawn_points_recursive(node: Node) -> Array:
	"""Recursively search for PlayerSpawnPoint nodes"""
	var spawn_points = []

	# Check if this node is a PlayerSpawnPoint
	if node.get_class() == "Node3D" and node.get_script():
		var script = node.get_script()
		if script and script.get_global_name() == "PlayerSpawnPoint":
			spawn_points.append(node)

	# Check children
	for child in node.get_children():
		spawn_points.append_array(find_player_spawn_points_recursive(child))

	return spawn_points

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

@rpc("any_peer", "call_local", "reliable")
func notify_player_leaving(peer_id: int) -> void:
	"""RPC called when a player is intentionally leaving the game"""
	print("[World] Received notification that player ", peer_id, " is leaving")

	# Remove the player immediately
	if players.has(peer_id):
		var player = players[peer_id]
		if player and is_instance_valid(player):
			print("[World] Removing player node for leaving peer ", peer_id)
			player.queue_free()
		players.erase(peer_id)

	# Remove from dead players if they were dead
	if dead_players.has(peer_id):
		dead_players.erase(peer_id)

	print("[World] Player ", peer_id, " removed due to intentional leave. Remaining: ", players.keys())

func _on_player_disconnected(id: int) -> void:
	"""Called when a player disconnects (Alt+F4, network issue, or intentional leave)"""
	print("[World] Player ", id, " disconnected - removing from game")

	# Remove player from players dictionary
	if players.has(id):
		var player = players[id]
		if player and is_instance_valid(player):
			print("[World] Removing player node for peer ", id)
			player.queue_free()
		players.erase(id)

	# Remove from dead players if they were dead
	if dead_players.has(id):
		dead_players.erase(id)
		print("[World] Removed peer ", id, " from dead players list")

	print("[World] Player ", id, " fully removed. Remaining players: ", players.keys())

	# If all players have disconnected and we're the server, we might want to handle that
	if is_multiplayer and multiplayer.is_server() and players.size() == 0:
		print("[World] All players have disconnected from server")

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

	# Determine if this is the host/first player
	var is_host = false
	if is_multiplayer:
		# Check if this is the server/host
		is_host = (peer_id == 1) or (multiplayer.is_server() and peer_id == multiplayer.get_unique_id())

	# Host spawns randomly, others spawn near host
	if is_host or players.size() == 0:
		# Host or first player - spawn at random safe position across the entire map
		spawn_pos = find_safe_spawn_position(current_world_name, 100, 2.0)
		print("Spawning host/first player ", peer_id, " at position: ", spawn_pos)
	else:
		# Other players - find the host and spawn near them
		var host_id = 1 if multiplayer.is_server() else multiplayer.get_unique_id()
		var host_player = players.get(host_id)

		if host_player and is_instance_valid(host_player):
			# Spawn near the host's position (3-8 units away)
			spawn_pos = find_spawn_near_player(host_player.global_position)
			print("Spawning player ", peer_id, " near host at position: ", spawn_pos)
		else:
			# Fallback: if host not found, spawn at random position
			spawn_pos = find_safe_spawn_position(current_world_name, 100, 2.0)
			print("Host not found, spawning player ", peer_id, " at random position: ", spawn_pos)

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

	# Voice settings UI removed - file no longer exists

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
# Only counts alive players (not dead/spectating)
func get_total_player_count() -> int:
	var alive_count = 0
	for peer_id in players:
		if not dead_players.has(peer_id):
			alive_count += 1
	return alive_count

# Called by dream_helper when player collects it
@rpc("any_peer", "call_local", "reliable")
func reduce_nightmare_from_item(reduction_amount: float) -> void:
	# Only server handles the actual reduction in multiplayer
	if is_multiplayer and not multiplayer.is_server():
		# Client sends request to server
		reduce_nightmare_from_item.rpc_id(1, reduction_amount)
		return

	# Reduce nightmare value
	nightmare_value -= reduction_amount
	nightmare_value = clamp(nightmare_value, 0, 100)
	nightmare_bar.value = nightmare_value

	print("Nightmare reduced by ", reduction_amount, "% (now at ", nightmare_value, "%)")

	# Sync to clients in multiplayer
	if is_multiplayer and multiplayer.is_server():
		sync_nightmare_value.rpc(nightmare_value)

# Called by end_object when player activates it (bed)
@rpc("any_peer", "call_local", "reliable")
func teleport_from_end_object() -> void:
	print("=== TELEPORT FROM END OBJECT CALLED ===")
	print("is_multiplayer: ", is_multiplayer)
	if is_multiplayer:
		print("is_server: ", multiplayer.is_server())

	# Only server handles the actual teleportation
	if is_multiplayer and not multiplayer.is_server():
		# Client sends request to server
		print("Client sending teleport request to server")
		teleport_from_end_object.rpc_id(1)
		return

	# NEW GAMEPLAY:
	# - If in nightmare world: Reset nightmare to 0%
	# - If in dream world: Reduce nightmare by 75%
	# - Reset all dead players (they respawn when sleeping)
	print("Current world: ", current_world_name)
	print("Is in nightmare world: ", is_in_nightmare_world())
	print("Nightmare value before: ", nightmare_value)

	# Reset dead players - everyone respawns when sleeping
	dead_players.clear()
	print("Dead players cleared - all players respawned")

	# Clean up spectator camera if it exists
	if has_meta("spectator_camera"):
		var spectator_camera = get_meta("spectator_camera")
		if spectator_camera and is_instance_valid(spectator_camera):
			spectator_camera.queue_free()
		remove_meta("spectator_camera")
		remove_meta("spectator_target_id")

	# Re-enable controls for all players
	for peer_id in players:
		var player = players[peer_id]
		if player and player.has_method("enable_controls"):
			player.enable_controls()

	# Calculate the new nightmare value
	var new_nightmare_value: float
	if is_in_nightmare_world():
		new_nightmare_value = 0.0
		print("In nightmare world - will reset nightmare to 0%")
	else:
		# In dream world - reduce by 75%
		new_nightmare_value = max(nightmare_value - 75.0, 0.0)
		print("In dream world - will reduce nightmare by 75%")

	# Teleport to a random NORMAL world (not nightmare)
	var available_worlds = worlds.keys()
	available_worlds.erase(current_world_name)  # Don't teleport to current world

	# If currently in a nightmare, also exclude the corresponding dream world
	if is_in_nightmare_world():
		var world_number = current_world_name.substr(9)  # Get number from "nightmare1"
		var corresponding_world = "world" + world_number
		available_worlds.erase(corresponding_world)

	if available_worlds.size() > 0:
		var random_world = available_worlds[randi() % available_worlds.size()]

		# Teleport with random spawn positions (NOT keeping positions)
		# Pass the new nightmare value to be set AFTER the world transition
		var spawn_position = find_safe_spawn_position(random_world)
		teleport_to_world(random_world, spawn_position, false, new_nightmare_value)

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

			# Check if local player is sprinting
			var local_player_id = multiplayer.get_unique_id()
			var is_sprinting = false
			if players.has(local_player_id):
				var local_player = players[local_player_id]
				if "is_sprinting" in local_player:
					is_sprinting = local_player.is_sprinting

			# Send to each nearby peer individually (targeted RPC) with sprint status
			for peer_id in nearby_peers:
				send_voice_packet.rpc_id(peer_id, pcm_data, is_sprinting)

@rpc("any_peer", "unreliable_ordered", "call_remote")
func send_voice_packet(pcm_voice: PackedByteArray, is_sprinting: bool = false):
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
			player.receive_voice_data(pcm_voice, is_sprinting)

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

		print("Audio settings loaded - Music: ", music_volume, "% SFX: ", sfx_volume, "% Voices: ", voices_volume, "%")
	else:
		# Use defaults (100%)
		set_bus_volume(BUS_MUSIC, 100)
		set_bus_volume(BUS_SFX, 100)
		set_bus_volume(BUS_VOICES, 100)
		print("No saved audio settings found, using defaults")

func set_bus_volume(bus_index: int, volume_percent: float):
	"""Set audio bus volume from percentage (0-100)"""
	if volume_percent <= 0:
		AudioServer.set_bus_mute(bus_index, true)
		print("Muted bus ", bus_index)
	else:
		AudioServer.set_bus_mute(bus_index, false)
		# Convert percentage to decibels with logarithmic curve
		var normalized = volume_percent / 100.0
		var db = -40 + (40 * normalized * normalized)
		AudioServer.set_bus_volume_db(bus_index, db)
		print("Set bus ", bus_index, " to ", volume_percent, "% (", db, " dB)")

func toggle_settings_menu():
	"""Toggle settings menu on/off with ESC key"""
	if settings_menu_instance:
		# Settings menu is open, close it
		close_settings_menu()
	else:
		# Settings menu is closed, open it
		open_settings_menu()

func open_settings_menu():
	"""Open settings menu as overlay without leaving the game"""
	# Prevent opening multiple instances
	if settings_menu_instance:
		return

	var settings_scene = load("res://scenes/settings_menu.tscn")
	if settings_scene:
		settings_menu_instance = settings_scene.instantiate()
		# Add as child to CanvasLayer so it appears on top
		$CanvasLayer.add_child(settings_menu_instance)
		# Game stays unpaused - no pause when opening settings

func close_settings_menu():
	"""Close the settings menu"""
	if settings_menu_instance:
		settings_menu_instance.queue_free()
		settings_menu_instance = null

func open_dev_terminal():
	"""Open dev terminal as overlay"""
	# Prevent opening multiple instances
	if dev_terminal_instance:
		return

	var terminal_scene = load("res://scenes/dev_terminal.tscn")
	if terminal_scene:
		dev_terminal_instance = terminal_scene.instantiate()
		# Add as child to CanvasLayer so it appears on top
		$CanvasLayer.add_child(dev_terminal_instance)
		# Show the terminal
		if dev_terminal_instance.has_method("show_terminal"):
			dev_terminal_instance.show_terminal()

func close_dev_terminal():
	"""Close the dev terminal"""
	if dev_terminal_instance:
		if dev_terminal_instance.has_method("hide_terminal"):
			dev_terminal_instance.hide_terminal()
		dev_terminal_instance.queue_free()
		dev_terminal_instance = null
