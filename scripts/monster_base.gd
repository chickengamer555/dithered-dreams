@tool
extends CharacterBody3D
class_name MonsterBase

# ========== EXPORTS ==========
@export_group("Monster Configuration")
@export var monster_type: MonsterType = MonsterType.CHASER_JUMPSCARE

@export_group("Movement")
@export var speed: float = 4.0  # How fast the monster moves (units per second)

@export var body_radius: float = 0.6  # Fallback radius; auto-detected from CollisionShape if present

@export_group("Visual")
@export var model_scene: PackedScene:
	set(value):
		model_scene = value
		_update_model()

@export_group("Detection")
@export var player_detection_range: float = 1000.0  # Max distance to detect players (increased for testing)
@export var player_update_interval: float = 0.5  # How often to search for nearest player (seconds)

@export_group("Navigation")
@export var use_navigation: bool = true  # Use NavigationAgent3D for pathfinding

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
@export var debug_path_height: float = 0.1
@export var enable_debug_prints: bool = true  # Toggle debug console output (enabled by default for debugging)

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

# Physics constants
const GRAVITY: float = 40.0  # Strong gravity for weight
const ROTATION_SPEED: float = 8.0  # How fast monster rotates to face target
const ACCELERATION: float = 15.0  # How fast monster accelerates
const DECELERATION: float = 15.0  # How fast monster stops

# Player detection optimization
var player_update_timer: float = 0.0

# 🔥 ULTIMATE PATHFINDING SYSTEM 🔥
var lazy_theta_star = null  # Legacy placeholder (removed)
var orca_avoidance = null  # Legacy placeholder (removed)
var current_path = []  # Current path (can be Array[Vector3] or PackedVector3Array)
var current_path_index: int = 0  # Current waypoint
var path_update_timer: float = 0.0
@export var path_update_interval: float = 0.2  # 5 updates per second (reduced from 20 for stability)
@export var waypoint_reach_distance: float = 0.8  # Larger radius helps round corners and prevents corner-sticking

# Movement state
var current_velocity: Vector3 = Vector3.ZERO

# Stuck detection
var stuck_timer: float = 0.0
var stuck_threshold: float = 0.6  # Faster recovery when wedged
var last_position: Vector3 = Vector3.ZERO
var position_change_threshold: float = 0.5  # Must move at least 0.5m per second

# Cached effective body radius (computed from CollisionShape3D if available)
var _cached_body_radius: float = -1.0

# Debug throttling
var debug_frame_counter: int = 0
# Debug path mesh holder
var _debug_path_mesh: Node3D = null
var _debug_points: MultiMeshInstance3D = null

# ========== INITIALIZATION ==========
func _ready():
	# Load model first
	_update_model()

	# Skip game logic in editor
	if Engine.is_editor_hint():
		return

	# Get world script reference
	world_script = get_tree().root.get_node_or_null("world")

	# Fallback for test scenes: auto-find a Player node if no world_script or no target set
	if target_player == null:
		var scene_root := get_tree().current_scene
		if scene_root:
			var p := scene_root.get_node_or_null("Player")
			if p and p is Node3D:
				target_player = p
			else:
				var found := get_tree().root.find_child("Player", true, false)
				if found and found is Node3D:
					target_player = found

# 🔥 CREATE ULTIMATE PATHFINDING SYSTEM (legacy) 🔥

	if false:
		print("[MonsterBase] 🔥 Initializing Lazy Theta* + ORCA for: ", name)



		# Initialize pathfinding asynchronously (non-blocking)
		_initialize_pathfinding()

		print("[MonsterBase] ⏳ Pathfinding initialization started...")
	else:
		# Legacy pathfinding disabled for this instance (e.g., test scene using new nav)
		lazy_theta_star = null
		orca_avoidance = null

func _initialize_pathfinding():
	"""Initialize pathfinding system asynchronously"""
	# Wait for physics then initialize
	await get_tree().physics_frame
	await get_tree().physics_frame

	if lazy_theta_star:
		await lazy_theta_star.initialize()
		print("[MonsterBase] ✅ Lazy Theta* + ORCA ready!")
		print("[MonsterBase] Grid size: ", lazy_theta_star.grid.size() if lazy_theta_star.grid else 0)
		print("[MonsterBase] Monster position: ", global_position)

		# CRITICAL FIX: Validate grid is not empty
		if lazy_theta_star.grid.size() == 0:
			print("[MonsterBase] ❌ CRITICAL: Pathfinding grid is EMPTY!")
			print("[MonsterBase] This means the monster cannot pathfind at all.")
			print("[MonsterBase] Will fall back to direct chase mode.")
	else:
		print("[MonsterBase] ❌ Failed to initialize - lazy_theta_star is null!")

func _update_model():
	"""Load or reload the model"""
	if model_instance:
		model_instance.queue_free()
		model_instance = null

	if model_scene:
		model_instance = model_scene.instantiate()
		add_child(model_instance)
	# Invalidate cached radius; model may include collision shape with different size
	_cached_body_radius = -1.0

# ========== PHYSICS & BEHAVIOR ==========
func _physics_process(delta: float):
	if Engine.is_editor_hint():
		return

	# CRITICAL FIX: Update player detection timer
	# Only auto-update target if we have world_script (multiplayer mode)
	# In test scenes, target_player is set manually and should not be overwritten
	player_update_timer += delta
	if player_update_timer >= player_update_interval:
		player_update_timer = 0.0
		if world_script:  # Only auto-find in multiplayer mode
			target_player = _find_nearest_player()
		# else: keep manually-set target_player for test scenes

	# Execute behavior based on type (this sets horizontal velocity X/Z)
	match monster_type:
		MonsterType.CHASER_JUMPSCARE:
			_behavior_chaser_jumpscare(delta)
		MonsterType.CHASER_LETHAL:
			_behavior_chaser_lethal(delta)
		MonsterType.CHASER_JUMPSCARE_REPEAT:
			_behavior_chaser_jumpscare_repeat(delta)

	# Apply gravity AFTER behavior (preserve X/Z set by pathfinding)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	# Apply movement with collision detection - this respects walls and obstacles
	move_and_slide()

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
			velocity = Vector3(0, velocity.y, 0)
	else:
		# No valid target, stop moving
		velocity = Vector3(0, velocity.y, 0)

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
			velocity = Vector3(0, velocity.y, 0)
	else:
		# No valid target, stop moving
		velocity = Vector3(0, velocity.y, 0)

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
			velocity = Vector3(0, velocity.y, 0)
	else:
		# No valid target, stop moving
		velocity = Vector3(0, velocity.y, 0)

func _chase_player(delta: float):
	"""Chase player using ULTIMATE Lazy Theta* + ORCA pathfinding"""
	debug_frame_counter += 1
	var should_print = enable_debug_prints and (debug_frame_counter % 60 == 0)

	if not target_player or not is_instance_valid(target_player):
		# Try to auto-acquire a Player in test scenes if none is set
		var scene_root := get_tree().current_scene
		if scene_root:
			var p := scene_root.get_node_or_null("Player")
			if p and p is Node3D:
				target_player = p
			else:
				var found := get_tree().root.find_child("Player", true, false)
				if found and found is Node3D:
					target_player = found
		# If still no target, stop this frame
		if not target_player or not is_instance_valid(target_player):
			if should_print:
				print("[MonsterBase] ❌ No target player!")
			velocity = Vector3(0, velocity.y, 0)
			return

	# If legacy system is disabled, use the new NavRuntime pathfinding
	if true:
		# Ensure nav is baked (synchronous for small test scenes)
		if NavRuntime and not NavRuntime.is_ready():
			var scene_root := get_tree().current_scene
			if scene_root:
				NavRuntime.ensure_ready(scene_root)
		# Update/request path on interval
		path_update_timer += delta
		if path_update_timer >= path_update_interval:
			path_update_timer = 0.0
			# CRITICAL: Enable optimize=true for more efficient paths
			var packed: PackedVector3Array = NavRuntime.get_nav_path(global_position, target_player.global_position, true) if NavRuntime else PackedVector3Array()

			# Debug: Print path info occasionally
			if should_print and packed.size() > 0:
				var straight_dist = global_position.distance_to(target_player.global_position)
				var path_length = _calculate_path_length(packed)
				print("[MonsterBase] Path: ", packed.size(), " waypoints | Straight: ", snappedf(straight_dist, 1), "m | Path: ", snappedf(path_length, 1), "m | Ratio: ", snappedf(path_length / straight_dist, 2))

			# If we can see the player with corridor clearance, short-circuit to a single target
			if _corridor_clear(global_position, target_player.global_position, _effective_body_radius()):
				packed = PackedVector3Array([target_player.global_position])
			# REDUCED path simplification for more accurate paths
			if packed.size() >= 3:
				var eps: float = maxf(0.05, _effective_body_radius() * 0.3)  # Reduced from 0.8 to 0.3
				packed = NavigationServer3D.simplify_path(packed, eps)
			if packed.size() > 0:
				current_path = packed
				current_path_index = 0
				if show_debug_path:
					_refresh_debug_path_mesh()
		# Follow path if available; otherwise fall back to direct chase
		if current_path.size() == 0:
			_chase_direct(delta, target_player.global_position)
			return
		if current_path_index >= current_path.size():
			# End of path; request refresh next tick
			path_update_timer = path_update_interval
			velocity = Vector3(0, velocity.y, 0)
			return
		# Try to skip ahead to the farthest visible waypoint to round corners
		_advance_waypoint_visible(12)
		var raw_wp: Vector3 = current_path[current_path_index]
		var waypoint: Vector3 = _offset_waypoint_clear(raw_wp)
		var flat_vec := waypoint - global_position
		flat_vec.y = 0
		var scale: float = _uniform_scale()
		var reach: float = maxf(waypoint_reach_distance * scale, _effective_body_radius() * scale * 0.9)
		if flat_vec.length() < reach:
			current_path_index += 1
			if current_path_index >= current_path.size():
				path_update_timer = path_update_interval
				velocity = Vector3(0, velocity.y, 0)
				return
			flat_vec = current_path[current_path_index] - global_position
			flat_vec.y = 0
			# Move toward waypoint with simple wall avoidance
		var forward: Vector3 = flat_vec.normalized()
		var avoid: Vector3 = _wall_avoidance_vector(_effective_body_radius())
		var steer: Vector3 = (forward + avoid * 0.9).normalized()
		var desired := steer * speed
		var old_y := velocity.y
		velocity.x = desired.x
		velocity.z = desired.z
		velocity.y = old_y
		# Face movement
		var turn_eps: float = 0.05 * _uniform_scale()
		if desired.length() > turn_eps:
			var face := atan2(desired.x, desired.z)
			rotation.y = lerp_angle(rotation.y, face, delta * ROTATION_SPEED)

		# Lightweight stuck handling: if not moving enough, skip waypoint or replan
		var moved := global_position.distance_to(last_position)
		var intended_speed := desired.length()
		var stuck_eps: float = 0.1 * _uniform_scale()
		if intended_speed > 0.2 and moved < stuck_eps:
			stuck_timer += delta
			if stuck_timer >= stuck_threshold:
				if current_path_index < current_path.size() - 1:
					current_path_index += 1
				else:
					# Force replan next tick
					path_update_timer = path_update_interval
				stuck_timer = 0.0
		else:
			stuck_timer = maxf(0.0, stuck_timer - delta * 2.0)
		last_position = global_position
		return

	# CRITICAL FIX: Better validation of pathfinding readiness
	var pathfinding_ready = (
		lazy_theta_star != null and
		lazy_theta_star.is_initialized and
		lazy_theta_star.grid.size() > 0 and
		orca_avoidance != null
	)

	if not pathfinding_ready:
		# Fallback to direct movement if pathfinding not ready
		if should_print:
			print("[MonsterBase] ⚠️ Pathfinding not ready, using direct chase")
			if lazy_theta_star:
				print("   Grid size: ", lazy_theta_star.grid.size() if lazy_theta_star.grid else "NULL")
		_chase_direct(delta, target_player.global_position)
		return

	# Update path using Lazy Theta* (ALWAYS update timer, even if no path)
	path_update_timer += delta
	if path_update_timer >= path_update_interval:
		path_update_timer = 0.0
		var new_path = lazy_theta_star.find_path(global_position, target_player.global_position)

		# Only update if we got a valid path, or if we have no path
		if new_path.size() > 0 or current_path.size() == 0:
			current_path = new_path
			current_path_index = 0
			if should_print:
				print("[MonsterBase] 🛤️ Path updated: ", current_path.size(), " waypoints")

	# Follow path with ORCA avoidance
	if current_path.size() == 0:
		# No path found, try direct chase as fallback
		if should_print:
			print("[MonsterBase] ⚠️ No path found, using direct chase")
		_chase_direct(delta, target_player.global_position)
		return

	if current_path_index >= current_path.size():
		# Reached end of path, request new path
		if should_print:
			print("[MonsterBase] 🏁 Reached path end, requesting new path")
		path_update_timer = path_update_interval  # Force immediate path update
		velocity = Vector3(0, velocity.y, 0)
		return

	# Get target waypoint
	var target = current_path[current_path_index]
	var to_target = target - global_position
	to_target.y = 0

	if should_print:
		print("[MonsterBase] 🎯 Waypoint ", current_path_index, "/", current_path.size(), " | Distance: ", snappedf(to_target.length(), 0.01))

	# Check if reached waypoint
	if to_target.length() < waypoint_reach_distance:
		current_path_index += 1
		if should_print:
			print("[MonsterBase] ✅ Reached waypoint ", current_path_index - 1)
		if current_path_index >= current_path.size():
			path_update_timer = path_update_interval  # Force immediate path update
			velocity = Vector3(0, velocity.y, 0)
			return
		target = current_path[current_path_index]
		to_target = target - global_position
		to_target.y = 0

	# Calculate desired velocity (Vector3)
	var desired_velocity = to_target.normalized() * speed

	# Apply ORCA avoidance (convert to Vector2 for ORCA, then back to Vector3)
	var current_vel_2d = Vector2(velocity.x, velocity.z)
	var desired_vel_2d = Vector2(desired_velocity.x, desired_velocity.z)

	var safe_velocity_2d = orca_avoidance.compute_safe_velocity(
		global_position,
		current_vel_2d,
		desired_vel_2d,
	)

	# CRITICAL FIX: Limit ORCA deviation from desired path
	# If ORCA deviates more than 75°, blend back toward desired velocity
	var desired_angle = desired_vel_2d.angle()
	var safe_angle = safe_velocity_2d.angle()
	var angle_diff = abs(wrapf(safe_angle - desired_angle, -PI, PI))

	var MAX_ORCA_DEVIATION = deg_to_rad(75.0)
	if angle_diff > MAX_ORCA_DEVIATION and desired_vel_2d.length() > 0.1:
		# ORCA is fighting pathfinding too hard - blend toward desired velocity
		var blend_factor = (angle_diff - MAX_ORCA_DEVIATION) / (PI - MAX_ORCA_DEVIATION)
		safe_velocity_2d = safe_velocity_2d.lerp(desired_vel_2d, blend_factor * 0.7)

		if should_print:
			print("[MonsterBase] ⚠️ ORCA deviation too large (", snappedf(rad_to_deg(angle_diff), 1), "°), blending toward path")

	# Re-apply speed limit after blending
	safe_velocity_2d = safe_velocity_2d.limit_length(speed)

	if should_print:
		print("[MonsterBase] 🚀 Desired: ", desired_vel_2d, " → Safe: ", safe_velocity_2d)

	# CRITICAL FIX: Apply velocity (convert Vector2 back to Vector3)
	# Preserve Y velocity for gravity
	var old_y_velocity = velocity.y
	velocity.x = safe_velocity_2d.x
	velocity.z = safe_velocity_2d.y  # Vector2.y maps to Vector3.z
	velocity.y = old_y_velocity  # Restore gravity

	# Rotate to face movement direction
	if safe_velocity_2d.length() > 0.1:
		var target_rotation = atan2(safe_velocity_2d.x, safe_velocity_2d.y)
		rotation.y = lerp_angle(rotation.y, target_rotation, delta * ROTATION_SPEED)

	# CRITICAL FIX: Detect if we're stuck against a wall
	var intended_velocity = velocity
	var intended_speed = Vector2(intended_velocity.x, intended_velocity.z).length()

	# CRITICAL FIX: Don't call move_and_slide() here!
	# It's already called once in _physics_process at line 178
	# Calling it twice causes velocity corruption and freezing

	# CRITICAL FIX: Check if we got stuck (velocity was significantly reduced by collision)
	var actual_velocity = velocity
	var actual_speed = Vector2(actual_velocity.x, actual_velocity.z).length()

	# IMPROVED STUCK DETECTION: Track position change over time
	var position_change = global_position.distance_to(last_position)

	# If we intended to move but barely moved, increment stuck timer
	if intended_speed > 1.0 and actual_speed < intended_speed * 0.3:
		stuck_timer += delta

		if should_print:
			print("[MonsterBase] 🚧 STUCK! Intended: ", snappedf(intended_speed, 0.1), " Actual: ", snappedf(actual_speed, 0.1), " Timer: ", snappedf(stuck_timer, 0.1))

		# CRITICAL FIX: Wait for stuck_threshold before taking action
		# Don't skip waypoints immediately - give ORCA time to resolve
		if stuck_timer >= stuck_threshold:
			if should_print:
				print("[MonsterBase] 🆘 STUCK THRESHOLD REACHED!")

			# Action 1: Try skipping current waypoint (might be blocked)
			if current_path_index < current_path.size() - 1:
				current_path_index += 1
				stuck_timer = 0.0  # Reset timer
				if should_print:
					print("[MonsterBase] ⏭️ Skipped waypoint, trying next")
			else:
				# Action 2: At last waypoint and stuck - force replan
				if should_print:
					print("[MonsterBase] 🔄 Forcing path replan")
				current_path.clear()
				current_path_index = 0
				path_update_timer = path_update_interval
				stuck_timer = 0.0

				# Action 3: Lateral sidestep along corridor to unhook from wall
				var side := Vector3(-to_target.z, 0, to_target.x).normalized()
				velocity.x = side.x * speed * 0.8
				velocity.z = side.z * speed * 0.8
	else:
		# Moving successfully - decay stuck timer
		stuck_timer = maxf(0.0, stuck_timer - delta * 2.0)

	last_position = global_position

	# CRITICAL FIX: Update current_velocity for next ORCA iteration
	# This ensures ORCA knows our actual velocity after collision response
	current_velocity = velocity



# Visibility and waypoint helpers for robust path following

# Effective body radius, auto-detected from attached CollisionShape3D if possible.
func _effective_body_radius() -> float:
	if _cached_body_radius > 0.0:
		return _cached_body_radius
	var r: float = body_radius
	# Gather collision shapes recursively
	var shapes: Array = []
	_gather_collision_shapes(self, shapes)
	for cs in shapes:
		if cs == null: continue
		var sh: Shape3D = cs.shape
		if sh == null: continue
		var local_r: float = 0.0
		if sh is SphereShape3D:
			local_r = (sh as SphereShape3D).radius
		elif sh is CapsuleShape3D:
			local_r = (sh as CapsuleShape3D).radius
		elif sh is CylinderShape3D:
			local_r = (sh as CylinderShape3D).radius
		elif sh is BoxShape3D:
			var ext: Vector3 = (sh as BoxShape3D).extents
			local_r = maxf(ext.x, ext.z)
		# Apply this shape node's global horizontal scale to radius
		var sc: Vector3 = cs.global_transform.basis.get_scale().abs()
		var hscale: float = maxf(sc.x, sc.z)
		if hscale <= 0.0001:
			hscale = 1.0
		local_r *= hscale
		if local_r > r:


			r = local_r
	_cached_body_radius = r
	return r


# Offset a waypoint slightly away from nearby walls to avoid grazing corners
func _offset_waypoint_clear(wp: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return wp
	var scale := _uniform_scale()
	var r: float = _effective_body_radius() * scale
	var heights: Array[float] = [0.4 * scale, 1.0 * scale, 1.4 * scale]
	var dirs: Array[Vector3] = [
		Vector3(1,0,0), Vector3(-1,0,0),
		Vector3(0,0,1), Vector3(0,0,-1),
		Vector3(0.707,0,0.707), Vector3(-0.707,0,0.707),
		Vector3(0.707,0,-0.707), Vector3(-0.707,0,-0.707)
	]
	var accum: Vector3 = Vector3.ZERO
	for h in heights:
		var o: Vector3 = wp + Vector3.UP * h
		for d in dirs:
			var p: PhysicsRayQueryParameters3D = _make_ray(o, o + d * (r * 1.1))
			var hit: Dictionary = space.intersect_ray(p)
			if not hit.is_empty():
				var n: Vector3 = hit.get("normal", Vector3.ZERO)
				accum += n
	accum.y = 0.0
	if accum.length() > 0.001:
		var n: Vector3 = accum.normalized()
		return wp + n * (r * 0.6)
	return wp

# Build/refresh a simple line mesh to visualize the current path
func _refresh_debug_path_mesh() -> void:
	# In Forward+ renderer, line primitives are not visible. Use MultiMesh point markers.
	if not show_debug_path:
		if _debug_points and is_instance_valid(_debug_points):
			_debug_points.queue_free()
			_debug_points = null
		return
	var count: int = current_path.size()
	if count == 0:
		if _debug_points and is_instance_valid(_debug_points):
			_debug_points.visible = false
		return
	if not _debug_points or not is_instance_valid(_debug_points):
		_debug_points = MultiMeshInstance3D.new()
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		_debug_points.multimesh = mm
		# Small unshaded box markers
		var box := BoxMesh.new()
		box.size = Vector3(0.08, 0.08, 0.08) * maxf(1.0, _uniform_scale())
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.1, 1.0, 0.1, 1.0)
		box.material = mat
		_debug_points.multimesh.mesh = box
		add_child(_debug_points)
	_debug_points.visible = true
	var mmesh: MultiMesh = _debug_points.multimesh
	mmesh.instance_count = count
	var h: float = debug_path_height * _uniform_scale()
	for i in range(count):
		var wp: Vector3 = current_path[i]
		var lp: Vector3 = to_local(wp) + Vector3.UP * h
		mmesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, lp))

# Helper: recursively collect CollisionShape3D nodes
func _gather_collision_shapes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			out.append(child)
		if child.get_child_count() > 0:
			_gather_collision_shapes(child, out)
# Build a standard raycast query that ignores our own collision layer
func _make_ray(from_point: Vector3, to_point: Vector3) -> PhysicsRayQueryParameters3D:
	var p := PhysicsRayQueryParameters3D.create(from_point, to_point)
	# Hit anything, but ignore our own body RID only
	p.collision_mask = 0xFFFFFFFF
	p.collide_with_areas = true
	p.collide_with_bodies = true
	p.hit_from_inside = true
	p.hit_back_faces = true
	p.exclude = [get_rid()]
	return p


func _uniform_scale() -> float:
	var s: Vector3 = global_transform.basis.get_scale().abs()
	var u: float = maxf(s.x, maxf(s.y, s.z))
	return u if u > 0.0001 else 1.0


func _is_visible_3d(from_point: Vector3, to_point: Vector3) -> bool:
	return _corridor_clear(from_point, to_point, _effective_body_radius())

func _corridor_clear(from_point: Vector3, to_point: Vector3, radius: float) -> bool:
	# Robust line-of-sight: sample three heights and left/right offsets to approximate agent width
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return false
	var a: Vector3 = from_point
	var b: Vector3 = to_point
	var dir: Vector3 = b - a
	dir.y = 0.0
	var len: float = dir.length()
	if len < 0.05:
		return true
	dir = dir / len
	var scale: float = _uniform_scale()
	var r: float = radius * scale
	var side: Vector3 = Vector3(-dir.z, 0.0, dir.x) * maxf(0.0, r)
	var heights: Array[float] = [0.4 * scale, 1.0 * scale, 1.6 * scale]
	for i in range(heights.size()):
		var h: float = heights[i]
		var o_center: Vector3 = a + Vector3.UP * h
		var d_center: Vector3 = b + Vector3.UP * h
		# center ray
		var p: PhysicsRayQueryParameters3D = _make_ray(o_center, d_center)
		var hit: Dictionary = space.intersect_ray(p)
		if not hit.is_empty():
			return false
		# left and right offset rays
		var o_left: Vector3 = o_center + side
		var d_left: Vector3 = d_center + side
		p = _make_ray(o_left, d_left)
		hit = space.intersect_ray(p)
		if not hit.is_empty():
			return false
		var o_right: Vector3 = o_center - side
		var d_right: Vector3 = d_center - side
		p = _make_ray(o_right, d_right)
		hit = space.intersect_ray(p)
		if not hit.is_empty():
			return false
	return true

# Lightweight avoidance to keep distance from walls in any scale
func _wall_avoidance_vector(radius: float) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return Vector3.ZERO
	var scale: float = _uniform_scale()
	var r: float = maxf(0.1, radius * scale)
	var heights: Array[float] = [0.4 * scale, 1.0 * scale, 1.4 * scale]
	var dirs: Array[Vector3] = [
		Vector3(1,0,0), Vector3(-1,0,0),
		Vector3(0,0,1), Vector3(0,0,-1),
		Vector3(0.707,0,0.707), Vector3(-0.707,0,0.707),
		Vector3(0.707,0,-0.707), Vector3(-0.707,0,-0.707)
	]
	var accum: Vector3 = Vector3.ZERO
	for h in heights:
		var o: Vector3 = global_position + Vector3.UP * h
		for d in dirs:
			var p: PhysicsRayQueryParameters3D = _make_ray(o, o + d * (r * 1.5))
			var hit: Dictionary = space.intersect_ray(p)
			if not hit.is_empty():
				var n: Vector3 = hit.get("normal", Vector3.ZERO)
				accum += n
	# Also use recent slide collisions as wall normals (very reliable when wedged)
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		if col:
			accum += col.get_normal()
	accum.y = 0.0
	if accum.length() > 0.001:
		return accum.normalized()
	return Vector3.ZERO



func _advance_waypoint_visible(max_lookahead: int = 2) -> void:
	if current_path_index >= current_path.size():
		return
	var best := current_path_index
	var upper: int = min(current_path_index + max_lookahead, current_path.size() - 1)
	# Prefer the farthest visible waypoint
	for i in range(upper, current_path_index, -1):
		if _corridor_clear(global_position, current_path[i], _effective_body_radius()):
			best = i
			break
	current_path_index = best

func _calculate_path_length(path: PackedVector3Array) -> float:
	"""Calculate total length of a path"""
	if path.size() < 2:
		return 0.0
	var length = 0.0
	for i in range(path.size() - 1):
		length += path[i].distance_to(path[i + 1])
	return length

func _chase_direct(delta: float, player_pos: Vector3):
	"""Chase using direct movement (no navigation)"""
	var monster_pos = global_position
	var to_player = player_pos - monster_pos
	to_player.y = 0
	var distance_to_player = to_player.length()

	if distance_to_player < 0.1:
		return

	var direction_to_player = to_player.normalized()

	# Simple direct movement toward player
	velocity.x = direction_to_player.x * speed
	velocity.z = direction_to_player.z * speed

	# Rotate to face player
	var target_rotation = atan2(direction_to_player.x, direction_to_player.z)
	rotation.y = lerp_angle(rotation.y, target_rotation, delta * ROTATION_SPEED)

# OLD PATHFINDING METHODS REMOVED - NOW USING LAZY THETA* + ORCA

func _find_nearest_player() -> Node3D:
	"""Find closest player within detection range (only alive players)"""
	if not world_script:
		# Don't spam - this is normal in test scenes
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
	_remove_monster()

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
		_remove_monster()

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
	_remove_monster()

func _remove_monster():
	"""Remove this monster and register its death for respawning"""
	# Register death with world script so it can be respawned later
	if world_script and world_script.has_method("register_monster_death"):
		world_script.register_monster_death(self)

	# Remove from scene
	queue_free()
