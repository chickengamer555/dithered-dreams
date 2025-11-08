extends Node
class_name DynamicPathfinding

## DYNAMIC A* PATHFINDING SYSTEM
## Fully dynamic grid-based pathfinding using AStar3D
## No navigation mesh baking required - real-time obstacle detection!

# Grid configuration
@export var grid_cell_size: float = 1.0  # Size of each grid cell (smaller = more precise, slower)
@export var grid_bounds: Vector2 = Vector2(100, 100)  # Grid size in world units (X, Z)
@export var grid_center: Vector3 = Vector3.ZERO  # Center of the grid
@export var max_slope: float = 45.0  # Maximum walkable slope in degrees
@export var agent_height: float = 2.0  # Height of the agent (for ceiling checks)
@export var agent_radius: float = 0.5  # Radius of the agent (for wall clearance)

# Performance settings
@export var use_path_cache: bool = true  # Cache paths for performance
@export var cache_lifetime: float = 2.0  # How long to cache paths (seconds)
@export var diagonal_cost_multiplier: float = 1.414  # Cost for diagonal movement (sqrt(2))

# Debug settings
@export var debug_print: bool = true  # Print debug information
@export var visualize_grid: bool = true  # Draw grid points (expensive!)
@export var visualize_connections: bool = true  # Draw grid connections

# Internal state
var astar: AStar3D = null
var grid_points: Dictionary = {}  # Maps Vector2i(x,z) -> point_id
var point_positions: Dictionary = {}  # Maps point_id -> Vector3
var next_point_id: int = 0
var is_initialized: bool = false

# Path caching
var cached_paths: Dictionary = {}  # Maps "start_end" -> {path: Array, timestamp: float}

# Physics query
var space_state: PhysicsDirectSpaceState3D = null

# Debug visualization
var debug_visualization_parent: Node3D = null
var blocked_connections: Array[Array] = []  # Store blocked connections for visualization

func _ready():
	print("🔧 DynamicPathfinding: Initializing...")

	# Initialize AStar3D immediately
	astar = AStar3D.new()

	# Create debug visualization parent
	if visualize_grid or visualize_connections:
		debug_visualization_parent = Node3D.new()
		debug_visualization_parent.name = "PathfindingDebugVisualization"
		get_tree().root.add_child(debug_visualization_parent)

	# Wait for physics to be fully ready before building grid
	await get_tree().create_timer(0.1).timeout

	# Get physics space from viewport (works from any Node)
	space_state = get_viewport().get_world_3d().direct_space_state

	if not space_state:
		print("❌ ERROR: Could not get physics space state!")
		return

	# Build the grid
	_build_grid()

	# Visualize grid after building
	if visualize_grid or visualize_connections:
		_visualize_grid()

	is_initialized = true
	print("✅ DynamicPathfinding: Ready! Grid size: ", grid_points.size(), " points")

func _build_grid():
	"""Build the pathfinding grid by raycasting to detect walkable areas"""
	print("🏗️ Building pathfinding grid...")

	var start_time = Time.get_ticks_msec()

	# Clear previous data
	blocked_connections.clear()

	# Calculate grid bounds
	var half_bounds = grid_bounds / 2.0
	var min_x = grid_center.x - half_bounds.x
	var max_x = grid_center.x + half_bounds.x
	var min_z = grid_center.z - half_bounds.y
	var max_z = grid_center.z + half_bounds.y

	var cells_x = int(grid_bounds.x / grid_cell_size)
	var cells_z = int(grid_bounds.y / grid_cell_size)

	print("  Grid cells: ", cells_x, " x ", cells_z, " = ", cells_x * cells_z, " total")
	print("  Grid bounds: X[", min_x, " to ", max_x, "] Z[", min_z, " to ", max_z, "]")

	# First pass: Add all walkable points
	var walkable_points: Array[Vector2i] = []
	var points_with_ground = 0
	var points_no_ground = 0

	for x in range(cells_x):
		for z in range(cells_z):
			var world_x = min_x + (x * grid_cell_size) + (grid_cell_size / 2.0)
			var world_z = min_z + (z * grid_cell_size) + (grid_cell_size / 2.0)
			var world_pos = Vector3(world_x, grid_center.y, world_z)

			# Check if this position is walkable
			var ground_pos = _find_ground(world_pos)
			if ground_pos != null:
				# Add point to AStar
				var point_id = next_point_id
				next_point_id += 1

				astar.add_point(point_id, ground_pos)

				var grid_coord = Vector2i(x, z)
				grid_points[grid_coord] = point_id
				point_positions[point_id] = ground_pos
				walkable_points.append(grid_coord)
				points_with_ground += 1
			else:
				points_no_ground += 1

	print("  Walkable points: ", walkable_points.size(), " / ", cells_x * cells_z)
	print("  Points with ground: ", points_with_ground)
	print("  Points without ground: ", points_no_ground)

	# Second pass: Connect neighboring points
	var connections_made = 0
	var connections_blocked = 0

	for grid_coord in walkable_points:
		var point_id = grid_points[grid_coord]

		# Check 8 directions (including diagonals)
		var neighbors = [
			Vector2i(1, 0),   # Right
			Vector2i(-1, 0),  # Left
			Vector2i(0, 1),   # Down
			Vector2i(0, -1),  # Up
			Vector2i(1, 1),   # Down-Right
			Vector2i(1, -1),  # Up-Right
			Vector2i(-1, 1),  # Down-Left
			Vector2i(-1, -1), # Up-Left
		]

		for offset in neighbors:
			var neighbor_coord = grid_coord + offset

			if grid_points.has(neighbor_coord):
				var neighbor_id = grid_points[neighbor_coord]

				# Check if connection is valid (not blocked by walls)
				if _is_connection_valid(point_id, neighbor_id):
					# Calculate cost (diagonal moves cost more)
					var is_diagonal = offset.x != 0 and offset.y != 0
					var cost = grid_cell_size * (diagonal_cost_multiplier if is_diagonal else 1.0)

					# Connect bidirectionally
					if not astar.are_points_connected(point_id, neighbor_id):
						astar.connect_points(point_id, neighbor_id, true)
						connections_made += 1
				else:
					connections_blocked += 1
					# Store blocked connection for visualization
					blocked_connections.append([point_positions[point_id], point_positions[neighbor_id]])

	var elapsed = Time.get_ticks_msec() - start_time
	print("  Connections made: ", connections_made)
	print("  Connections blocked by walls: ", connections_blocked)
	print("  Total raycasts performed: ", _debug_raycast_count)
	print("  Total raycast hits: ", _debug_hit_count)
	print("✅ Grid built in ", elapsed, "ms")

var _debug_ground_fail_count = 0

func _find_ground(position: Vector3) -> Variant:
	"""Raycast down to find ground level. Returns Vector3 or null"""
	if not space_state:
		print("⚠️ _find_ground: No space_state!")
		return null

	# Raycast from above to below
	var ray_start = position + Vector3(0, 50, 0)
	var ray_end = position - Vector3(0, 50, 0)

	var query = PhysicsRayQueryParameters3D.new()
	query.from = ray_start
	query.to = ray_end
	query.collision_mask = 1  # Layer 1 = static geometry
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var result = space_state.intersect_ray(query)

	if result.size() > 0:
		var ground_y = result.position.y

		# Check if there's enough headroom (ceiling check)
		if _has_headroom(result.position):
			# Return position slightly above ground
			return Vector3(position.x, ground_y + 0.1, position.z)
		else:
			# No headroom - print for first few
			if _debug_ground_fail_count < 3:
				print("  ⚠️ No headroom at ", position)
				_debug_ground_fail_count += 1
	else:
		# No ground found - print for first few
		if _debug_ground_fail_count < 3:
			print("  ⚠️ No ground found at ", position, " (raycast from ", ray_start, " to ", ray_end, ")")
			_debug_ground_fail_count += 1

	return null

func _has_headroom(ground_pos: Vector3) -> bool:
	"""Check if there's enough vertical space for the agent"""
	if not space_state:
		return true
	
	var ray_start = ground_pos + Vector3(0, 0.1, 0)
	var ray_end = ground_pos + Vector3(0, agent_height, 0)
	
	var query = PhysicsRayQueryParameters3D.new()
	query.from = ray_start
	query.to = ray_end
	query.collision_mask = 1
	query.collide_with_bodies = true
	query.collide_with_areas = false
	
	var result = space_state.intersect_ray(query)
	
	# If raycast hits something, there's not enough headroom
	return result.size() == 0

var _debug_raycast_count = 0
var _debug_hit_count = 0

func _is_connection_valid(point_id_a: int, point_id_b: int) -> bool:
	"""Check if two points can be connected (no walls between them)"""
	if not space_state:
		if debug_print:
			print("⚠️ No space_state available for connection check")
		return true

	var pos_a = point_positions[point_id_a]
	var pos_b = point_positions[point_id_b]

	# Multiple raycasts at different heights to ensure no walls
	var heights = [
		agent_height * 0.25,  # Lower
		agent_height * 0.5,   # Middle
		agent_height * 0.75   # Upper
	]

	for height in heights:
		var ray_start = pos_a + Vector3(0, height, 0)
		var ray_end = pos_b + Vector3(0, height, 0)

		var query = PhysicsRayQueryParameters3D.new()
		query.from = ray_start
		query.to = ray_end
		query.collision_mask = 1  # Only check layer 1 (static geometry)
		query.collide_with_bodies = true
		query.collide_with_areas = false
		# Exclude dynamic objects (CharacterBody3D like players/monsters)
		query.exclude = []

		var result = space_state.intersect_ray(query)

		_debug_raycast_count += 1

		# If any raycast hits something, check if it's a static obstacle
		if result.size() > 0:
			var collider = result.get("collider")
			# Only block if it's a StaticBody3D (walls/obstacles), not CharacterBody3D (player/monster)
			if collider is StaticBody3D:
				_debug_hit_count += 1
				# Print first few hits for debugging
				if _debug_hit_count <= 5 and debug_print:
					print("  🚫 Raycast HIT at height ", height, ": ", collider)
				return false

	# Also check with agent radius offset to account for width
	if agent_radius > 0.1:
		var direction = (pos_b - pos_a).normalized()
		var perpendicular = Vector3(-direction.z, 0, direction.x) * agent_radius * 0.5

		# Check both sides
		for offset in [perpendicular, -perpendicular]:
			var ray_start = pos_a + Vector3(0, agent_height * 0.5, 0) + offset
			var ray_end = pos_b + Vector3(0, agent_height * 0.5, 0) + offset

			var query = PhysicsRayQueryParameters3D.new()
			query.from = ray_start
			query.to = ray_end
			query.collision_mask = 1
			query.collide_with_bodies = true
			query.collide_with_areas = false

			var result = space_state.intersect_ray(query)
			_debug_raycast_count += 1

			if result.size() > 0:
				var collider = result.get("collider")
				# Only block if it's a StaticBody3D
				if collider is StaticBody3D:
					_debug_hit_count += 1
					return false

	return true

func find_path(from: Vector3, to: Vector3, use_cache: bool = true) -> Array[Vector3]:
	"""Find a path from 'from' to 'to' using A* pathfinding"""
	if not is_initialized:
		if debug_print:
			print("⚠️ DynamicPathfinding: Not initialized yet!")
		return []
	
	# Check cache first
	if use_cache and use_path_cache:
		var cache_key = _get_cache_key(from, to)
		if cached_paths.has(cache_key):
			var cached = cached_paths[cache_key]
			var age = Time.get_ticks_msec() / 1000.0 - cached.timestamp
			if age < cache_lifetime:
				if debug_print:
					print("📦 Using cached path (age: ", snappedf(age, 0.1), "s)")
				return cached.path
	
	# Find nearest grid points
	var start_id = _get_nearest_point(from)
	var end_id = _get_nearest_point(to)
	
	if start_id == -1 or end_id == -1:
		if debug_print:
			print("❌ Could not find valid grid points near start/end")
		return []
	
	# Calculate path using AStar3D
	var path_ids = astar.get_id_path(start_id, end_id)
	
	if path_ids.size() == 0:
		if debug_print:
			print("❌ No path found!")
		return []
	
	# Convert point IDs to world positions
	var path: Array[Vector3] = []
	for point_id in path_ids:
		path.append(point_positions[point_id])

	# Simplify path (remove unnecessary waypoints)
	path = _simplify_path(path)
	
	# Cache the result
	if use_path_cache:
		var cache_key = _get_cache_key(from, to)
		cached_paths[cache_key] = {
			"path": path,
			"timestamp": Time.get_ticks_msec() / 1000.0
		}
	
	return path

func _get_nearest_point(world_pos: Vector3) -> int:
	"""Find the nearest grid point to a world position"""
	# Convert world position to grid coordinates
	var half_bounds = grid_bounds / 2.0
	var min_x = grid_center.x - half_bounds.x
	var min_z = grid_center.z - half_bounds.y
	
	var grid_x = int((world_pos.x - min_x) / grid_cell_size)
	var grid_z = int((world_pos.z - min_z) / grid_cell_size)
	
	var grid_coord = Vector2i(grid_x, grid_z)
	
	# Check if this exact grid point exists
	if grid_points.has(grid_coord):
		return grid_points[grid_coord]
	
	# Search nearby points (spiral search)
	for radius in range(1, 10):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) == radius or abs(dz) == radius:  # Only check perimeter
					var check_coord = grid_coord + Vector2i(dx, dz)
					if grid_points.has(check_coord):
						return grid_points[check_coord]
	
	return -1

func _simplify_path(path: Array[Vector3]) -> Array[Vector3]:
	"""Remove unnecessary waypoints using line-of-sight checks"""
	if path.size() <= 2:
		return path
	
	var simplified: Array[Vector3] = [path[0]]
	var current_index = 0
	
	while current_index < path.size() - 1:
		var farthest_visible = current_index + 1
		
		# Find the farthest point we can see from current point
		for i in range(current_index + 2, path.size()):
			if _has_line_of_sight(path[current_index], path[i]):
				farthest_visible = i
			else:
				break
		
		simplified.append(path[farthest_visible])
		current_index = farthest_visible
	
	return simplified

func _has_line_of_sight(from: Vector3, to: Vector3) -> bool:
	"""Check if there's a clear line of sight between two points"""
	if not space_state:
		return true

	# Check multiple heights to be thorough
	var heights = [agent_height * 0.25, agent_height * 0.5, agent_height * 0.75]

	for height in heights:
		var ray_start = from + Vector3(0, height, 0)
		var ray_end = to + Vector3(0, height, 0)

		var query = PhysicsRayQueryParameters3D.new()
		query.from = ray_start
		query.to = ray_end
		query.collision_mask = 1
		query.collide_with_bodies = true
		query.collide_with_areas = false

		var result = space_state.intersect_ray(query)
		if result.size() > 0:
			return false

	return true

func _get_cache_key(from: Vector3, to: Vector3) -> String:
	"""Generate a cache key from two positions"""
	# Round to grid cells to increase cache hits
	var from_grid = Vector2i(int(from.x / grid_cell_size), int(from.z / grid_cell_size))
	var to_grid = Vector2i(int(to.x / grid_cell_size), int(to.z / grid_cell_size))
	return str(from_grid) + "_" + str(to_grid)

func clear_cache():
	"""Clear the path cache"""
	cached_paths.clear()
	if debug_print:
		print("🧹 Path cache cleared")

func rebuild_grid():
	"""Rebuild the entire grid (call this if world changes significantly)"""
	print("🔄 Rebuilding pathfinding grid...")
	astar.clear()
	grid_points.clear()
	point_positions.clear()
	next_point_id = 0
	cached_paths.clear()
	_build_grid()

	# Re-visualize if enabled
	if visualize_grid or visualize_connections:
		_visualize_grid()

func _visualize_grid():
	"""Create visual representation of the grid"""
	if not debug_visualization_parent:
		return

	# Clear existing visualization
	for child in debug_visualization_parent.get_children():
		child.queue_free()

	# Load visualizer script
	var visualizer_script = load("res://scripts/pathfinding_debug_visualizer.gd")
	if not visualizer_script:
		print("❌ Could not load pathfinding_debug_visualizer.gd")
		return

	var visualizer = Node3D.new()
	visualizer.set_script(visualizer_script)
	debug_visualization_parent.add_child(visualizer)

	# Wait for visualizer to be ready
	await get_tree().process_frame

	# Draw the grid
	if visualizer.has_method("draw_grid"):
		visualizer.draw_grid(astar, point_positions, blocked_connections)
