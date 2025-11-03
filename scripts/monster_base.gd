@tool
extends CharacterBody3D
class_name MonsterBase

# ========== EXPORTS ==========
@export_group("Monster Configuration")
@export var monster_type: MonsterType = MonsterType.CHASER_JUMPSCARE

@export_group("Movement")
@export var speed: float = 4.0  # How fast the monster moves (units per second)

@export_group("Visual")
@export var model_scene: PackedScene:
	set(value):
		model_scene = value
		_update_model()

@export_group("Detection")
@export var player_detection_range: float = 100.0  # Max distance to detect players
@export var player_update_interval: float = 0.5  # How often to search for nearest player (seconds)

@export_group("Respawn (for CHASER_JUMPSCARE_REPEAT)")
# Monster will look for MonsterSpawnPoint nodes in the world to respawn at
enum SpawnPointSelection {
	CLOSE,    # Spawn at closest spawn point to player
	FAR,      # Spawn at farthest spawn point from player
	RANDOM    # Spawn at random spawn point
}
@export var spawn_point_mode: SpawnPointSelection = SpawnPointSelection.RANDOM

@export_group("Debug")
@export var show_debug_path: bool = false
@export var enable_debug_prints: bool = false  # Toggle debug console output

# ========== MONSTER TYPES ==========
enum MonsterType {
	CHASER_JUMPSCARE,
	CHASER_LETHAL,
	CHASER_JUMPSCARE_REPEAT,
}

# ========== INTERNAL STATE ==========
var world_script: Node = null
var model_instance: Node3D = null
var target_player: Node3D = null
var navigation_agent: NavigationAgent3D
var navigation_ready: bool = false

# Physics constants
const GRAVITY: float = 40.0  # Strong gravity for weight
const ROTATION_SPEED: float = 8.0  # How fast monster rotates to face target
const ACCELERATION: float = 12.0  # How fast monster accelerates
const DECELERATION: float = 15.0  # How fast monster stops

# Player detection optimization
var player_update_timer: float = 0.0

# Movement state
var current_velocity: Vector3 = Vector3.ZERO

# ========== INITIALIZATION ==========
func _ready():
	# Load model first
	_update_model()

	# Skip game logic in editor
	if Engine.is_editor_hint():
		return

	# Setup navigation agent
	navigation_agent = NavigationAgent3D.new()
	add_child(navigation_agent)

	# Get the world scale to properly configure navigation
	# Monsters are scaled 0.1x in a world scaled 15x = effective 1.5x scale
	var world_scale = 1.5  # 0.1 * 15 = 1.5

	# Configure navigation properties (scaled for the world)
	navigation_agent.path_desired_distance = 2.0 * world_scale
	navigation_agent.target_desired_distance = 3.0 * world_scale
	navigation_agent.radius = 0.5 * world_scale
	navigation_agent.height = 2.0 * world_scale
	navigation_agent.avoidance_enabled = true
	navigation_agent.max_speed = speed * world_scale

	# Path recalculation settings for dynamic chasing
	navigation_agent.path_max_distance = 10.0 * world_scale

	# Get world script reference
	world_script = get_tree().root.get_node_or_null("world")

	# Wait for navigation map to synchronize (critical for pathfinding to work)
	call_deferred("_setup_navigation")

func _setup_navigation():
	"""Deferred navigation setup - waits for navigation server to be ready"""
	# Wait for physics frame to ensure navigation map is synchronized
	await get_tree().physics_frame
	await get_tree().physics_frame  # Extra frame for safety

	navigation_ready = true
	if enable_debug_prints:
		print("[MonsterBase] Navigation ready for: ", name)

	# Verify navigation map exists
	if not navigation_agent.get_navigation_map():
		push_error("[MonsterBase] No navigation map found! Add NavigationRegion3D to your world scene.")

func _update_model():
	"""Load or reload the model"""
	if model_instance:
		model_instance.queue_free()
		model_instance = null

	if model_scene:
		model_instance = model_scene.instantiate()
		add_child(model_instance)

# ========== PHYSICS & BEHAVIOR ==========
func _physics_process(delta: float):
	if Engine.is_editor_hint():
		return

	# Apply gravity - CRITICAL for proper physics
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
		# Clamp downward velocity to prevent infinite falling
		velocity.y = max(velocity.y, -50.0)
	else:
		# Reset vertical velocity when on floor to prevent sliding
		velocity.y = -0.1

	# Update player detection timer
	player_update_timer += delta
	if player_update_timer >= player_update_interval:
		player_update_timer = 0.0
		target_player = _find_nearest_player()

	# Execute behavior based on type (this sets horizontal velocity only)
	match monster_type:
		MonsterType.CHASER_JUMPSCARE:
			_behavior_chaser_jumpscare(delta)
		MonsterType.CHASER_LETHAL:
			_behavior_chaser_lethal(delta)
		MonsterType.CHASER_JUMPSCARE_REPEAT:
			_behavior_chaser_jumpscare_repeat(delta)

	# Apply movement with collision detection - this respects walls and obstacles
	move_and_slide()

	# Debug collision and floor detection
	if enable_debug_prints:
		if get_slide_collision_count() > 0:
			for i in get_slide_collision_count():
				var collision = get_slide_collision(i)
				print("[MonsterBase] Collided with: ", collision.get_collider().name, " | Normal: ", collision.get_normal())

		# Print floor status periodically
		var current_second = int(Time.get_ticks_msec() / 1000.0)
		if current_second % 2 == 0:  # Every 2 seconds
			print("[MonsterBase] On floor: ", is_on_floor(), " | Y velocity: ", velocity.y, " | Position: ", global_position)

# ========== BEHAVIOR IMPLEMENTATIONS ==========
func _behavior_chaser_jumpscare(delta: float):
	"""Chase player and trigger jumpscare on contact"""
	if target_player and is_instance_valid(target_player):
		var distance = global_position.distance_to(target_player.global_position)

		# Trigger jumpscare if very close
		if distance < 2.0:
			_trigger_jumpscare()
			return

		# Chase player if within detection range
		if distance <= player_detection_range:
			_chase_player(delta)
		else:
			# Player too far, stop moving
			velocity.x = 0
			velocity.z = 0
	else:
		# No valid target, stop moving
		velocity.x = 0
		velocity.z = 0

func _behavior_chaser_lethal(delta: float):
	"""Chase player and kill on contact"""
	if target_player and is_instance_valid(target_player):
		var distance = global_position.distance_to(target_player.global_position)

		# Debug: Print distance to player
		if enable_debug_prints:
			print("[MonsterBase] Distance to player: ", distance)

		# Kill player if very close (increased from 1.5 to 3.0 for easier detection)
		if distance < 3.0:
			print("[MonsterBase] KILLING PLAYER - Distance: ", distance)
			_kill_player()
			return

		# Chase player if within detection range
		if distance <= player_detection_range:
			_chase_player(delta)
		else:
			# Player too far, stop moving
			velocity.x = 0
			velocity.z = 0
	else:
		# No valid target, stop moving
		velocity.x = 0
		velocity.z = 0

func _behavior_chaser_jumpscare_repeat(delta: float):
	"""Chase player and trigger jumpscare on contact, then respawn"""
	if target_player and is_instance_valid(target_player):
		var distance = global_position.distance_to(target_player.global_position)

		# Trigger jumpscare if very close
		if distance < 2.0:
			_trigger_jumpscare_and_respawn()
			return

		# Chase player if within detection range
		if distance <= player_detection_range:
			_chase_player(delta)
		else:
			# Player too far, stop moving
			velocity.x = 0
			velocity.z = 0
	else:
		# No valid target, stop moving
		velocity.x = 0
		velocity.z = 0

func _chase_player(delta: float):
	"""Use navigation to chase player with smooth, weighted movement"""
	# Don't move until navigation is ready
	if not navigation_ready:
		if enable_debug_prints:
			print("[MonsterBase] Navigation not ready yet")
		return

	if not target_player or not is_instance_valid(target_player):
		if enable_debug_prints:
			print("[MonsterBase] No valid target player!")
		# Smoothly decelerate to stop
		current_velocity.x = lerp(current_velocity.x, 0.0, delta * DECELERATION)
		current_velocity.z = lerp(current_velocity.z, 0.0, delta * DECELERATION)
		velocity.x = current_velocity.x
		velocity.z = current_velocity.z
		return

	if not navigation_agent:
		if enable_debug_prints:
			print("[MonsterBase] No navigation agent!")
		return

	# Update navigation target to player's current position
	navigation_agent.target_position = target_player.global_position

	# Get next waypoint in path (MUST be called every physics frame)
	var next_position = navigation_agent.get_next_path_position()

	# Calculate direction to next waypoint (not directly to player)
	var direction = (next_position - global_position)
	direction.y = 0  # Keep movement on horizontal plane

	var distance_to_waypoint = direction.length()

	if distance_to_waypoint > 0.1:
		direction = direction.normalized()

		# Calculate target velocity based on speed
		var target_velocity = direction * speed

		# Smoothly accelerate towards target velocity (gives weight/momentum)
		current_velocity.x = lerp(current_velocity.x, target_velocity.x, delta * ACCELERATION)
		current_velocity.z = lerp(current_velocity.z, target_velocity.z, delta * ACCELERATION)

		# Apply the smoothed velocity
		velocity.x = current_velocity.x
		velocity.z = current_velocity.z

		# Smoothly rotate to face movement direction
		var target_rotation = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, delta * ROTATION_SPEED)
	else:
		# Very close to waypoint, smoothly decelerate
		current_velocity.x = lerp(current_velocity.x, 0.0, delta * DECELERATION)
		current_velocity.z = lerp(current_velocity.z, 0.0, delta * DECELERATION)
		velocity.x = current_velocity.x
		velocity.z = current_velocity.z

# ========== HELPER FUNCTIONS ==========
func _find_nearest_player() -> Node3D:
	"""Find closest player within detection range (only alive players)"""
	if not world_script:
		if enable_debug_prints:
			print("[MonsterBase] ERROR: No world_script found!")
		return null

	if not "players" in world_script:
		if enable_debug_prints:
			print("[MonsterBase] ERROR: No 'players' property in world_script!")
		return null

	if world_script.players.is_empty():
		# No players in game yet - this is normal during initialization
		return null

	var nearest: Node3D = null
	var nearest_distance: float = INF
	var detection_range_sq = player_detection_range * player_detection_range

	# Get dead players dictionary if it exists
	var dead_players = {}
	if "dead_players" in world_script:
		dead_players = world_script.dead_players

	for peer_id in world_script.players:
		# Skip dead players
		if dead_players.has(peer_id):
			continue

		var player = world_script.players[peer_id]
		if player and is_instance_valid(player):
			var distance_sq = global_position.distance_squared_to(player.global_position)

			# Only consider players within detection range
			if distance_sq <= detection_range_sq and distance_sq < nearest_distance:
				nearest_distance = distance_sq
				nearest = player

	if enable_debug_prints:
		if nearest:
			print("[MonsterBase] Found nearest player at distance: ", sqrt(nearest_distance))
		else:
			print("[MonsterBase] No alive players found in range")

	return nearest

func _trigger_jumpscare():
	"""Trigger jumpscare scene and remove (non-lethal)"""
	print("[MonsterBase] JUMPSCARE triggered!")

	# Trigger non-lethal jumpscare (shows jumpscare scene then returns to game)
	if world_script and world_script.has_method("trigger_nonlethal_jumpscare"):
		world_script.trigger_nonlethal_jumpscare()

	# Remove this monster after triggering jumpscare
	queue_free()

func _trigger_jumpscare_and_respawn():
	"""Trigger jumpscare scene and respawn at spawn point (repeating jumpscare)"""
	print("[MonsterBase] JUMPSCARE triggered! Checking for spawn point...")

	# Trigger non-lethal jumpscare (shows jumpscare scene then returns to game)
	if world_script and world_script.has_method("trigger_nonlethal_jumpscare"):
		world_script.trigger_nonlethal_jumpscare()

	# Check if a MonsterSpawnPoint exists in the world
	var spawn_point = _find_monster_spawn_point()

	if spawn_point:
		# Spawn point found - respawn there
		var new_position = spawn_point.global_position
		global_position = new_position

		# Reset velocity
		velocity = Vector3.ZERO
		current_velocity = Vector3.ZERO

		print("[MonsterBase] Respawned at spawn point: ", new_position)
	else:
		# No spawn point found - remove the monster
		print("[MonsterBase] No MonsterSpawnPoint found in world - removing monster")
		queue_free()

func _find_monster_spawn_point() -> Node3D:
	"""Find a MonsterSpawnPoint node in the world based on spawn_point_mode"""
	# Search the entire scene tree for ALL MonsterSpawnPoints
	var root = get_tree().root
	var all_spawn_points = []
	_collect_all_spawn_points(root, all_spawn_points)

	if all_spawn_points.is_empty():
		return null

	# If only one spawn point, always use it regardless of mode
	if all_spawn_points.size() == 1:
		return all_spawn_points[0]

	# Multiple spawn points - select based on mode
	return _select_spawn_point(all_spawn_points)

func _collect_all_spawn_points(node: Node, spawn_points: Array) -> void:
	"""Recursively collect all MonsterSpawnPoint nodes in the scene tree"""
	# Check if this node is a MonsterSpawnPoint
	if node.is_class("Node3D") and node.get_script():
		var script = node.get_script()
		if script and script.resource_path.contains("monster_spawn_point.gd"):
			spawn_points.append(node as Node3D)

	# Check children
	for child in node.get_children():
		_collect_all_spawn_points(child, spawn_points)

func _select_spawn_point(spawn_points: Array) -> Node3D:
	"""Select a spawn point based on the spawn_point_mode"""
	if not target_player or not is_instance_valid(target_player):
		# No valid player, just return random spawn point
		return spawn_points[randi() % spawn_points.size()]

	var player_pos = target_player.global_position

	match spawn_point_mode:
		SpawnPointSelection.CLOSE:
			# Find closest spawn point to player
			var closest_point = spawn_points[0]
			var closest_distance = player_pos.distance_squared_to(closest_point.global_position)

			for i in range(1, spawn_points.size()):
				var distance = player_pos.distance_squared_to(spawn_points[i].global_position)
				if distance < closest_distance:
					closest_distance = distance
					closest_point = spawn_points[i]

			print("[MonsterBase] Selected CLOSEST spawn point at distance: ", sqrt(closest_distance))
			return closest_point

		SpawnPointSelection.FAR:
			# Find farthest spawn point from player
			var farthest_point = spawn_points[0]
			var farthest_distance = player_pos.distance_squared_to(farthest_point.global_position)

			for i in range(1, spawn_points.size()):
				var distance = player_pos.distance_squared_to(spawn_points[i].global_position)
				if distance > farthest_distance:
					farthest_distance = distance
					farthest_point = spawn_points[i]

			print("[MonsterBase] Selected FARTHEST spawn point at distance: ", sqrt(farthest_distance))
			return farthest_point

		SpawnPointSelection.RANDOM:
			# Pick a random spawn point
			var random_point = spawn_points[randi() % spawn_points.size()]
			print("[MonsterBase] Selected RANDOM spawn point")
			return random_point

	# Fallback (shouldn't reach here)
	return spawn_points[0]

func _kill_player():
	"""Kill the player"""
	print("[MonsterBase] PLAYER KILLED by lethal chaser!")
	print("[MonsterBase] Target player: ", target_player)
	print("[MonsterBase] World script: ", world_script)

	if not target_player or not is_instance_valid(target_player):
		print("[MonsterBase] ERROR: Invalid target player!")
		return

	# Call death handler in world script
	if world_script and world_script.has_method("_player_killed"):
		print("[MonsterBase] Calling world_script._player_killed()")
		world_script._player_killed(target_player)
	else:
		print("[MonsterBase] ERROR: No world script or _player_killed method!")

	# Remove this monster after killing player
	queue_free()

# ========== DEBUG VISUALIZATION ==========
func _process(_delta: float):
	if Engine.is_editor_hint() or not show_debug_path:
		return

	if navigation_ready and navigation_agent and target_player:
		# Draw debug line to next waypoint
		var next_pos = navigation_agent.get_next_path_position()
		DebugDraw3D.draw_line_3d(global_position, next_pos, Color.RED)

		# Draw line to final target
		DebugDraw3D.draw_line_3d(global_position, target_player.global_position, Color.YELLOW)

		# Draw navigation path
		var current_path = navigation_agent.get_current_navigation_path()
		for i in range(current_path.size() - 1):
			DebugDraw3D.draw_line_3d(current_path[i], current_path[i + 1], Color.GREEN)

# Simple debug drawing if DebugDraw3D not available
class DebugDraw3D:
	static func draw_line_3d(from: Vector3, to: Vector3, color: Color):
		# This requires the debug draw addon or you can implement ImmediateMesh
		pass
