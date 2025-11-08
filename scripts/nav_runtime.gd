extends Node

# Code-only runtime navigation using NavigationServer3D (RIDs)
# Minimal single-region implementation for the test scene.
# Later this can be extended to chunked tiles and async baking.

@export var base_agent_radius: float = 0.6  # Base radius in unscaled world units; multiplied by root scale

var _map: RID
var _region: RID
var _navmesh: NavigationMesh
var _ready_baked: bool = false

# Optional: remember which root we baked from (for re-bake)
var _last_root: Node = null

# Track current scene to auto-bake per loaded world
var _auto_bake_last_scene: Node = null

# Track if last bake produced geometry and schedule delayed retry
var _last_bounds_empty: bool = true
var _rebake_delay_s: float = 0.5
var _rebake_timer: float = 0.0
# Control auto-retry behavior and adoption of external regions
var _using_external_regions: bool = false
var _rebake_attempts: int = 0
var _rebake_attempts_max: int = 6
var _rebake_backoff_max_s: float = 4.0
var _rebake_gave_up: bool = false



func _ready():
	# Create map/region once
	_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(_map, true)
	_region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(_region, _map)
	NavigationServer3D.region_set_enabled(_region, true)
	NavigationServer3D.map_set_up(_map, Vector3.UP)
	# Auto-bake for whichever scene is currently loaded
	set_process(true)

func is_ready() -> bool:
	return _ready_baked


func _process(delta: float) -> void:
	var cs := get_tree().current_scene
	if cs != null and cs != _auto_bake_last_scene:
		ensure_ready(cs)
		_auto_bake_last_scene = cs
	# If we baked too early (no geometry yet), try again after a short delay
	if cs != null and _ready_baked and _last_bounds_empty and not _using_external_regions:
		if _rebake_attempts < _rebake_attempts_max:
			_rebake_timer += delta
			if _rebake_timer >= _rebake_delay_s:
				_rebake_timer = 0.0
				_rebake_attempts += 1
				print("[NavRuntime] Previous bake had empty bounds; retrying (", _rebake_attempts, "/", _rebake_attempts_max, ") …")
				request_rebake()
				_rebake_delay_s = minf(_rebake_delay_s * 2.0, _rebake_backoff_max_s)
		elif not _rebake_gave_up:
			_rebake_gave_up = true
			push_warning("[NavRuntime] Gave up auto-rebaking after "+str(_rebake_attempts)+" attempts. Call NavRuntime.request_rebake() later or ensure your world instances NavigationRegion3D nodes.")

func ensure_ready(root: Node, force: bool = false) -> void:
	# Adopt existing region-based navigation if present to avoid double baking
	if root is Node3D and _detect_external_regions(root):
		_using_external_regions = true
		var w := (root as Node3D).get_world_3d()
		if w:
			_map = w.navigation_map
		# Disable our internal region to avoid extra work
		NavigationServer3D.region_set_enabled(_region, false)
		_ready_baked = true
		_last_bounds_empty = false
		_last_root = root
		print("[NavRuntime] Found NavigationRegion3D nodes; using world navigation map and skipping internal bake.")
		return
	# Synchronous bake for small test scenes
	if not force and _ready_baked and _last_root == root:
		return
	_bake_from_root(root)


func _detect_external_regions(root: Node) -> bool:
	var q: Array = [root]
	var steps: int = 0
	while q.size() > 0 and steps < 10000:
		steps += 1
		var n: Node = q.pop_back()
		if n is NavigationRegion3D:
			return true
		for ch in n.get_children():
			if ch is Node:
				q.push_back(ch)
	return false

func _bake_from_root(root: Node) -> void:
	if root == null:
		push_warning("NavRuntime.ensure_ready: root is null; cannot bake")
		return

	# Create and configure the NavigationMesh first (defines parse rules)
	_navmesh = NavigationMesh.new()
	# Parse both MeshInstances and Static Colliders so we always have geometry
	_navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_BOTH
	# Include all collision layers in bake (for static collider parsing)
	_navmesh.geometry_collision_mask = 0xFFFFFFFF
	# Determine uniform scale of the root (supports scaled worlds)
	var scale_factor: float = 1.0
	if root is Node3D:
		var n3d: Node3D = root
		var s: Vector3 = n3d.global_transform.basis.get_scale().abs()
		scale_factor = maxf(s.x, maxf(s.y, s.z))
	if scale_factor <= 0.0001:
		scale_factor = 1.0
	# Rasterization and agent settings (scaled)
	_navmesh.cell_size = 0.2 * scale_factor
	_navmesh.cell_height = 0.2 * scale_factor
	_navmesh.agent_radius = base_agent_radius * scale_factor
	_navmesh.agent_height = 1.8 * scale_factor
	_navmesh.agent_max_slope = 40.0
	_navmesh.agent_max_climb = 0.4 * scale_factor
	_navmesh.sample_partition_type = NavigationMesh.SAMPLE_PARTITION_WATERSHED
	print("[NavRuntime] Bake settings | scale=", scale_factor, " cell=", _navmesh.cell_size, "/", _navmesh.cell_height, " radius=", _navmesh.agent_radius, " height=", _navmesh.agent_height, " climb=", _navmesh.agent_max_climb)

	# Ensure map rasterization matches the navigation mesh
	NavigationServer3D.map_set_cell_size(_map, _navmesh.cell_size)
	NavigationServer3D.map_set_cell_height(_map, _navmesh.cell_height)

	# Build source geometry data from the current scene graph (main thread)
	var src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(_navmesh, src, root)

	# Bake navmesh from parsed source geometry (synchronous for this test)
	NavigationServer3D.bake_from_source_geometry_data(_navmesh, src)

	# Assign mesh to region
	NavigationServer3D.region_set_navigation_mesh(_region, _navmesh)
	NavigationServer3D.region_set_enabled(_region, true)
	# Identity transform (mesh already baked from source)
	NavigationServer3D.region_set_transform(_region, Transform3D.IDENTITY)
	var bounds: AABB = NavigationServer3D.region_get_bounds(_region)
	print("[NavRuntime] Baked region bounds:", bounds)
	_last_bounds_empty = bounds.size == Vector3.ZERO
	if _last_bounds_empty:
		push_warning("[NavRuntime] Baked navmesh has empty bounds (no polygons). Will retry soon.")
		_rebake_timer = 0.0
	else:
		# Successful bake: reset backoff
		_rebake_attempts = 0
		_rebake_delay_s = 0.5
		_rebake_gave_up = false
	_ready_baked = true
	_last_root = root


# Force re-bake of the current scene with the latest settings
func request_rebake() -> void:
	var cs := get_tree().current_scene
	if cs != null:
		_ready_baked = false
		ensure_ready(cs, true)

# Adjust base agent radius at runtime and trigger a re-bake
func set_base_agent_radius(r: float) -> void:
	base_agent_radius = maxf(0.0, r)
	request_rebake()

func get_nav_path(start: Vector3, goal: Vector3, optimize: bool = true) -> PackedVector3Array:
	if not _ready_baked:
		return PackedVector3Array()
	# Project start/goal onto navmesh to avoid edge hugging / off-mesh starts
	var s := NavigationServer3D.map_get_closest_point(_map, start)
	var g := NavigationServer3D.map_get_closest_point(_map, goal)
	return NavigationServer3D.map_get_path(_map, s, g, optimize)
