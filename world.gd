extends Node

@onready var worlds = { # Sets up the dictionaries of what worlds there are
	"world1": $SubViewportContainer/SubViewport/world1,
	"world2": $SubViewportContainer/SubViewport/world2,
}

@onready var nightmares = { # Sets up the dictionaries of what nightmares there are
	"nightmare1": $SubViewportContainer/SubViewport/nightmare1,
}

var environments = { # Loads the environment resources for each world and nightmare
	"world1": preload("res://envoirments/world1.tres"),
	"nightmare1": preload("res://envoirments/nightmare1.tres"),
	"world2": preload("res://envoirments/world2.tres"),
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
@export var time_before_nightmare: float = 30.0

@export var nightmare_chance: float = 20.0
@export var world_chance: float = 80.0

var current_world_name: String = "world1"

var nightmare_value = 0
var nightmare_speed = 0
@export var nightmare_increment: float = 1.0

var dream_value = 0
@export var dream_increment: float = 0.2

# Dictionaries to store original collision layers and masks
var original_collision_layers = {}
var original_collision_masks = {}

# **New Variable:** Flag to indicate if a transition is in progress
var is_transitioning: bool = false

func _ready():
	randomize()  # Starts random number generator
	nightmare_bar.value = nightmare_value  # Sets up the nightmare bar based on var
	var normal_worlds = worlds.keys()  # Gets the list of worlds
	if normal_worlds.size() > 0:  # Makes sure there are worlds available
		current_world_name = normal_worlds[randi() % normal_worlds.size()]  # Randomly chooses a world to spawn in
	else:
		return  # This runs if no worlds
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
		timer_label.text = str(play_time)
	
	# Ensure the transition_rect is initially hidden
	if transition_rect:
		transition_rect.visible = false

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
			# Pause or unpause the audio player using 'stream_paused'
			child.stream_paused = disable
			if disable:
				print("Paused AudioStreamPlayer:", child.name, "in", world.name)
			else:
				print("Playing AudioStreamPlayer:", child.name, "in", world.name)
		# Add more conditions here if you have other interactive node types
		
		# Recursively disable interactions for child nodes
		if child.get_child_count() > 0:
			_disable_interactions_in_world(child, disable)

func _on_world_timer_tick():
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
	# **Set the transition flag to true**
	is_transitioning = true
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

			var player = $SubViewportContainer/SubViewport/Player
			if player:
				player.global_transform.origin = spawn_position

func _on_area_3d_body_entered(body: Node3D):
	# **Check if a transition is not already in progress**
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
		var menu = main_menu_scene.instantiate()
		get_tree().root.add_child(menu)
		queue_free()

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
	if is_in_nightmare_world():
		nightmare_speed = 1.0
		dream_value = 0
	else:
		if is_moving:
			nightmare_speed = 0
			dream_value = 1.0
		else:
			nightmare_speed = 0.5
			dream_value = 0

func is_in_nightmare_world() -> bool:
	return current_world_name in nightmares

func _trigger_jumpscare():
	nightmare_value = 0
	nightmare_bar.value = nightmare_value
	_play_jumpscare_effects()
	go_to_main_menu()

func _play_jumpscare_effects():
	# Implement your jumpscare effects here
	pass

# **New Function:** Find a safe spawn position by checking for collisions
func find_safe_spawn_position(world_name: String, attempts: int = 10, radius: float = 1.0) -> Vector3:
	for i in range(attempts):
		var pos = get_random_spawn_position(world_name)
		if is_position_safe(pos, radius):
			return pos
	# Fallback to original method if no safe position is found
	return get_random_spawn_position(world_name)

# **Corrected Function:** Check if the position is free from collisions
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
	query.exclude = [ $SubViewportContainer/SubViewport/Player ]  # Ensure correct player node path
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = false
	# Removed: query.max_results = 1  # This property does not exist
	
	var result = space_state.intersect_shape(query, 1)
	
	return result.is_empty()

# **Unified Spawn Position Function**
func get_random_spawn_position(world_name: String) -> Vector3:
	if world_name.begins_with("world"):
		return get_random_spawn_position_in_world(world_name)
	elif world_name.begins_with("nightmare"):
		return get_random_spawn_position_in_nightmare(world_name)
	else:
		# Default fallback position if world type is unrecognized
		return Vector3.ZERO

func get_random_spawn_position_in_world(world_name: String) -> Vector3:
	# Adjusted spawn range based on world scale
	var min_x = -100
	var max_x = 100
	var min_y = 0.0
	var max_y = 0.0
	var min_z = -100
	var max_z = 100
	
	var random_x = randf_range(min_x, max_x)
	var random_y = randf_range(min_y, max_y)
	var random_z = randf_range(min_z, max_z)
	
	return Vector3(random_x, random_y, random_z)

func get_random_spawn_position_in_nightmare(nightmare_name: String) -> Vector3:
	# Adjusted spawn range based on world scale
	var min_x = -100
	var max_x = 100
	var min_y = 0.0
	var max_y = 0.0
	var min_z = -100
	var max_z = 100
	
	var random_x = randf_range(min_x, max_x)
	var random_y = randf_range(min_y, max_y)
	var random_z = randf_range(min_z, max_z)
	
	return Vector3(random_x, random_y, random_z)


func _on_area_3d_area_entered(area: Area3D) -> void:
	pass  # Replace with function body.

# Transition effect functions
func play_transition_effect(completion_callback: Callable):
	if transition_rect:
		transition_rect.visible = true
		transition_rect.modulate.a = 0.0  # Start from transparent
		var tween = create_tween()
		# Fade in
		tween.tween_property(transition_rect, "modulate:a", 1.0, 0.0)
		# After fade-in, call the completion_callback
		tween.tween_callback(completion_callback)
		# Fade out
		tween.tween_property(transition_rect, "modulate:a", 0.0, 0.5)
		# After fade-out, hide the transition_rect and reset the transition flag
		tween.tween_callback(Callable(self, "_hide_transition_rect"))

func _hide_transition_rect():
	if transition_rect:
		transition_rect.visible = false
	# **Reset the transition flag to false**
	is_transitioning = false
