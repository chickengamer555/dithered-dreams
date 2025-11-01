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

@export var play_time: int = 300
@export var main_menu_scene: PackedScene
var time_left: int = play_time
var timer: Timer

var world_timer: Timer
var time_in_world: float = 0.0
@export var time_before_nightmare: float = 15.0

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

	# Check if we're in multiplayer mode
	is_multiplayer = multiplayer.has_multiplayer_peer()
	print("World _ready - is_multiplayer: ", is_multiplayer)

	if is_multiplayer:
		print("Multiplayer mode detected!")
		print("Is server: ", multiplayer.is_server())
		print("My peer ID: ", multiplayer.get_unique_id())
		print("Connected peers: ", multiplayer.get_peers())
		print("Multiplayer peer type: ", multiplayer.multiplayer_peer.get_class())

		# Set up multiplayer callbacks
		multiplayer.peer_connected.connect(_on_player_connected)
		multiplayer.peer_disconnected.connect(_on_player_disconnected)
		multiplayer.connected_to_server.connect(_on_connected_to_server)

		# Hide the original single-player player
		var old_player = $SubViewportContainer/SubViewport/Player
		if old_player:
			old_player.queue_free()
			print("Removed single-player player node")

		# Spawn multiplayer players
		if multiplayer.is_server():
			print("SERVER: Spawning host player...")
			# Host spawns themselves immediately
			spawn_player(multiplayer.get_unique_id())
			# Spawn any already-connected clients
			print("SERVER: Checking for already-connected clients...")
			for peer_id in multiplayer.get_peers():
				print("SERVER: Spawning client ", peer_id)
				# Call spawn_player locally and remotely so everyone sees the new player
				spawn_player(peer_id)
		else:
			print("CLIENT: Waiting for server to spawn us...")
			# Client: wait for server to spawn us
			pass

	# Initialize timers and UI for everyone
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

	# **Important: Mark this scene as the current main scene.**
	get_tree().set_current_scene(self)

	# Only the server picks the starting world
	if is_multiplayer and not multiplayer.is_server():
		print("CLIENT: Waiting for server to tell us which world to start in...")
		# Client will receive the world via RPC - but still need to initialize worlds
		# Disable all worlds initially
		for world_name_iter in worlds.keys():
			var world_iter = worlds[world_name_iter]
			if world_iter:
				world_iter.visible = false
				_disable_interactions_in_world(world_iter, true)

		# Disable all nightmares initially
		for nightmare_name_iter in nightmares.keys():
			var nightmare_iter = nightmares[nightmare_name_iter]
			if nightmare_iter:
				nightmare_iter.visible = false
				_disable_interactions_in_world(nightmare_iter, true)
		return

	var normal_worlds = worlds.keys()  # Gets the list of worlds
	if normal_worlds.size() > 0:  # Makes sure there are worlds available
		current_world_name = normal_worlds[randi() % normal_worlds.size()]  # Randomly chooses a world
	else:
		return  # This runs if no worlds

	print("SERVER: Selected starting world: ", current_world_name)
	var spawn_position = find_safe_spawn_position(current_world_name)  # Gets safe random spawn position
	
	# Disable all worlds initially
	for world_name_iter in worlds.keys():
		var world_iter = worlds[world_name_iter]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)
			print("Disabled interactions for world:", world_name_iter)
	
	# Disable all nightmares initially
	for nightmare_name_iter in nightmares.keys():
		var nightmare_iter = nightmares[nightmare_name_iter]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)
			print("Disabled interactions for nightmare:", nightmare_name_iter)
	
	# Enable the starting world
	var starting_world = worlds[current_world_name]  # Sees what the starting world is
	if starting_world:
		starting_world.visible = true
		_disable_interactions_in_world(starting_world, false)
		print("Enabled interactions for starting world:", current_world_name)

	teleport_to_world(current_world_name, spawn_position)  # Teleports player to starting world and the safe spawn

	# Don't sync to clients here - do it when they connect in _on_player_connected
	# This ensures they're fully ready to receive the RPC

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
		elif child is AudioStreamPlayer:
			child.stream_paused = disable
			if disable:
				print("Paused AudioStreamPlayer:", child.name, "in", world.name)
			else:
				print("Playing AudioStreamPlayer:", child.name, "in", world.name)
		
		# Recursively disable interactions for child nodes
		if child.get_child_count() > 0:
			_disable_interactions_in_world(child, disable)

func _on_world_timer_tick():
	# Only server controls world transitions
	if is_multiplayer and not multiplayer.is_server():
		return

	time_in_world += 1.0
	if time_in_world >= time_before_nightmare:
		teleport_to_nightmare_world(current_world_name)
		time_in_world = 0.0

func teleport_to_nightmare_world(world_name: String):
	var nightmare_world_name = ""
	if world_name.begins_with("world"):
		var world_number = world_name.substr(5)
		nightmare_world_name = "nightmare" + world_number
	else:
		return
	if nightmare_world_name in nightmares:
		var spawn_position = find_safe_spawn_position(nightmare_world_name)
		teleport_to_world(nightmare_world_name, spawn_position)

func teleport_to_random_world():
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
	var available_worlds = worlds.keys()
	available_worlds.erase(current_world_name)
	if available_worlds.size() > 0:
		var random_world = available_worlds[randi() % available_worlds.size()]
		var spawn_position = find_safe_spawn_position(random_world)
		teleport_to_world(random_world, spawn_position)

func teleport_to_world(world_name: String, spawn_position: Vector3):
	is_transitioning = true

	# If multiplayer and server, sync to clients
	if is_multiplayer and multiplayer.is_server():
		print("SERVER: Syncing world transition to clients: ", world_name)
		sync_world_to_clients.rpc(world_name)

	play_transition_effect(Callable(self, "_do_teleport_to_world").bind(world_name, spawn_position))

func _do_teleport_to_world(world_name: String, spawn_position: Vector3):
	for world_name_iter in worlds.keys():
		var world_iter = worlds[world_name_iter]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)
			print("Disabled interactions for world:", world_name_iter)
	for nightmare_name_iter in nightmares.keys():
		var nightmare_iter = nightmares[nightmare_name_iter]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)
			print("Disabled interactions for nightmare:", nightmare_name_iter)
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

			# Teleport players
			if is_multiplayer:
				# Teleport all multiplayer players
				for peer_id in players:
					var player = players[peer_id]
					if player:
						player.global_transform.origin = spawn_position
			else:
				# Teleport single-player player
				var player = $SubViewportContainer/SubViewport/Player
				if player:
					player.global_transform.origin = spawn_position

func _on_area_3d_body_entered(body: Node3D):
	if not is_transitioning and body is CharacterBody3D:
		teleport_to_random_world()

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

func _process(delta):
	if nightmare_speed > 0:
		nightmare_value += nightmare_speed * delta * nightmare_increment
	elif dream_value > 0:
		nightmare_value -= dream_value * delta * dream_increment
	nightmare_value = clamp(nightmare_value, 0, 100)
	nightmare_bar.value = nightmare_value
	if nightmare_value >= 100:
		_trigger_jumpscare()

func update_nightmare_and_dream_speed(is_moving: bool):
	# In multiplayer, only update for the local player
	if is_multiplayer:
		var my_peer_id = multiplayer.get_unique_id()
		var my_player = players.get(my_peer_id, null)
		if my_player and my_player.has_method("is_multiplayer_authority"):
			# Only update if this is our player
			if not my_player.is_multiplayer_authority():
				return

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
	# Exclude all players from raycast
	var exclude_list = []
	for player in players.values():
		exclude_list.append(player)
	# Also exclude single-player if it still exists
	var single_player = $SubViewportContainer/SubViewport.get_node_or_null("Player")
	if single_player:
		exclude_list.append(single_player)
	query.exclude = exclude_list
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
	var world = get_tree().root.get_world_3d()
	var space_state = world.direct_space_state

	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = radius
	var transform = Transform3D(Basis.IDENTITY, pos)

	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = sphere_shape
	query.transform = transform
	query.margin = 0.1
	# Exclude all players from shape query
	var exclude_list = []
	for player in players.values():
		exclude_list.append(player)
	# Also exclude single-player if it still exists
	var single_player = $SubViewportContainer/SubViewport.get_node_or_null("Player")
	if single_player:
		exclude_list.append(single_player)
	query.exclude = exclude_list
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

# Sync world state to clients
@rpc("authority", "call_remote", "reliable")
func sync_world_to_clients(world_name: String) -> void:
	print("CLIENT: Received world sync - switching to: ", world_name)
	current_world_name = world_name

	# Disable all worlds
	for world_name_iter in worlds.keys():
		var world_iter = worlds[world_name_iter]
		if world_iter:
			world_iter.visible = false
			_disable_interactions_in_world(world_iter, true)

	# Disable all nightmares
	for nightmare_name_iter in nightmares.keys():
		var nightmare_iter = nightmares[nightmare_name_iter]
		if nightmare_iter:
			nightmare_iter.visible = false
			_disable_interactions_in_world(nightmare_iter, true)

	# Enable the synced world
	var target_world = worlds.get(world_name, nightmares.get(world_name, null))
	if target_world:
		target_world.visible = true
		_disable_interactions_in_world(target_world, false)
		print("CLIENT: Enabled world: ", world_name)

		# Set environment
		if world_environment and world_name in environments:
			world_environment.environment = environments[world_name]

		# If we have a player already spawned, teleport them to the world
		var my_peer_id = multiplayer.get_unique_id()
		if players.has(my_peer_id):
			var spawn_pos = find_safe_spawn_position(world_name)
			players[my_peer_id].global_position = spawn_pos
			print("CLIENT: Teleported player to spawn position: ", spawn_pos)

# Multiplayer player spawning
func _on_player_connected(id: int) -> void:
	print("Player connected to world: ", id)
	if multiplayer.is_server():
		print("Server spawning player: ", id)
		# Spawn the new player for everyone (call_local ensures it spawns on server too)
		spawn_player.rpc(id)

		# Sync the current world state to the newly connected client
		print("SERVER: Syncing world state to newly connected client: ", id)
		sync_world_to_clients.rpc_id(id, current_world_name)

		# Also sync all existing players to the new client
		print("SERVER: Syncing existing players to new client: ", id)
		for existing_peer_id in players.keys():
			if existing_peer_id != id:  # Don't spawn them twice
				spawn_player.rpc_id(id, existing_peer_id)

func _on_player_disconnected(id: int) -> void:
	print("Player disconnected: ", id)
	if players.has(id):
		players[id].queue_free()
		players.erase(id)

func _on_connected_to_server() -> void:
	print("Client connected to server! Requesting spawn...")

@rpc("any_peer", "call_local", "reliable")
func spawn_player(peer_id: int) -> void:
	print("spawn_player called for peer: ", peer_id)

	# Don't spawn if already exists
	if players.has(peer_id):
		print("Player ", peer_id, " already spawned!")
		return

	var player = multiplayer_player_scene.instantiate()
	player.name = str(peer_id)

	# Spawn at a safe position in the current world
	var spawn_pos = find_safe_spawn_position(current_world_name)
	player.global_position = spawn_pos

	# Add to the viewport
	$SubViewportContainer/SubViewport.add_child(player)
	players[peer_id] = player

	print("Player ", peer_id, " spawned at: ", spawn_pos)
	print("Total players now: ", players.size())
