@tool
extends Node3D

## INFINITE WANDERING CLIPMAP TERRAIN
## GPU-based infinite terrain with LOD rings that follow the camera

# Terrain settings
@export var lod_levels: int = 5  # Number of LOD rings
@export var base_mesh_size: float = 256.0  # Size of each LOD level (larger chunks)
@export var base_subdivisions: int = 64  # Subdivisions for highest detail LOD
@export var heightmap_scale: float = 0.01  # UV scale for heightmap sampling
@export var max_height: float = 20.0  # Maximum terrain height
@export var noise_seed: int = 0
@export var chunk_update_distance: float = 64.0  # How far to move before updating chunks



# Model spawning settings
@export_group("Model Spawning")
@export var model_amount: int = 0:  # Number of model types (creates this many slots)
	set(value):
		model_amount = value
		_resize_model_scenes()
		if Engine.is_editor_hint():
			notify_property_list_changed()
@export var model_scenes: Array[PackedScene] = []  # Drag and drop .tscn or .glb files here
@export var models_per_chunk_min: int = 5  # Minimum models to spawn per chunk
@export var models_per_chunk_max: int = 15  # Maximum models to spawn per chunk
@export var model_spawn_area_size: float = 256.0  # Size of area to spawn models in (matches base_mesh_size)
@export var model_min_distance: float = 10.0  # Minimum distance between models
@export var model_scale_min: float = 1.0  # Minimum random scale for models
@export var model_scale_max: float = 1.0  # Maximum random scale for models

# Internal references
var lod_meshes: Array[MeshInstance3D] = []
var terrain_material: ShaderMaterial
var collision_shape: CollisionShape3D
var static_body: StaticBody3D
var camera: Camera3D
var noise: FastNoiseLite
var last_chunk_update_pos: Vector3 = Vector3.ZERO  # Track when to update chunk positions

# Model spawning references
var spawned_models: Dictionary = {}  # Track spawned models per chunk: {chunk_coords: [model_instances]}
var chunk_model_positions: Dictionary = {}  # Track positions per chunk to avoid overlap

# Heightmap texture (generated from noise)
var heightmap_texture: NoiseTexture2D
var heightmap_normal_texture: NoiseTexture2D
var slope_noise_texture: NoiseTexture2D

func _ready():
	# Don't run terrain generation in editor
	if Engine.is_editor_hint():
		return

	print("=== INFINITE WANDERING CLIPMAP TERRAIN INITIALIZING ===")

	# Setup noise
	setup_noise()

	# Create heightmap textures
	create_heightmap_textures()

	# Create LOD terrain meshes
	create_lod_terrain_meshes()

	# Create collision for center area
	create_collision()

	# Find camera and center terrain on it
	await get_tree().process_frame
	camera = get_viewport().get_camera_3d()

	if camera:
		var cam_pos = camera.global_position
		last_chunk_update_pos = cam_pos

		# Snap camera position to chunk grid
		var snapped_pos = snap_to_chunk_grid(cam_pos)

		# Center all LOD meshes on snapped position
		for mesh_instance in lod_meshes:
			if mesh_instance:
				mesh_instance.global_position = snapped_pos

		# Center collision on snapped position
		if static_body:
			static_body.global_position = snapped_pos

	print("✓ Infinite clipmap terrain initialized with", lod_levels, "LOD levels!")
	print("  Chunk size:", base_mesh_size, "m | Update distance:", chunk_update_distance, "m")

	# Spawn initial models if configured
	if model_amount > 0 and model_scenes.size() > 0:
		update_model_chunks()

func _resize_model_scenes():
	"""Resize the model_scenes array when model_amount changes"""
	if model_scenes.size() < model_amount:
		# Add empty slots
		while model_scenes.size() < model_amount:
			model_scenes.append(null)
	elif model_scenes.size() > model_amount:
		# Remove extra slots
		model_scenes.resize(model_amount)

func setup_noise():
	if noise_seed == 0:
		noise_seed = randi()

	noise = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.005  # Lower frequency = larger hills
	noise.fractal_octaves = 6  # More octaves = more detail
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.0
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM

func create_heightmap_textures():
	# Main heightmap
	heightmap_texture = NoiseTexture2D.new()
	heightmap_texture.noise = noise
	heightmap_texture.width = 1024
	heightmap_texture.height = 1024
	heightmap_texture.seamless = true
	heightmap_texture.normalize = true
	
	# Normal map version
	heightmap_normal_texture = NoiseTexture2D.new()
	heightmap_normal_texture.noise = noise
	heightmap_normal_texture.width = 1024
	heightmap_normal_texture.height = 1024
	heightmap_normal_texture.seamless = true
	heightmap_normal_texture.as_normal_map = true
	heightmap_normal_texture.bump_strength = 2.0
	
	# Slope noise (inverted for edge detection)
	var slope_noise = FastNoiseLite.new()
	slope_noise.seed = noise_seed + 1
	slope_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	slope_noise.frequency = 0.02
	
	slope_noise_texture = NoiseTexture2D.new()
	slope_noise_texture.noise = slope_noise
	slope_noise_texture.width = 512
	slope_noise_texture.height = 512
	slope_noise_texture.seamless = true
	slope_noise_texture.invert = true

func create_lod_terrain_meshes():
	"""Create multiple LOD levels for infinite terrain"""
	# Load shader once
	var shader = load("res://Shaders/clipmap_terrain.gdshader")

	for lod in range(lod_levels):
		# Calculate size and subdivisions for this LOD level
		var lod_size = base_mesh_size * pow(2, lod)
		var lod_subdivs = max(8, base_subdivisions / pow(2, lod))  # Reduce detail for distant LODs

		# Create plane mesh
		var plane_mesh = PlaneMesh.new()
		plane_mesh.size = Vector2(lod_size, lod_size)
		plane_mesh.subdivide_width = int(lod_subdivs)
		plane_mesh.subdivide_depth = int(lod_subdivs)
		plane_mesh.orientation = PlaneMesh.FACE_Y

		# Create mesh instance
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = plane_mesh
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mesh_instance)

		# Setup material
		var material = ShaderMaterial.new()
		material.shader = shader

		# Set shader parameters
		material.set_shader_parameter("heightmap", heightmap_texture)
		material.set_shader_parameter("heightmap_normals", heightmap_normal_texture)
		material.set_shader_parameter("slope_edge_noise", slope_noise_texture)
		material.set_shader_parameter("heightmap_scale", heightmap_scale)
		material.set_shader_parameter("heightmap_height_scale", max_height)
		material.set_shader_parameter("slope_edge_noise_scale", heightmap_scale)
		material.set_shader_parameter("mesh_size", lod_size)

		mesh_instance.material_override = material

		# Store reference
		lod_meshes.append(mesh_instance)

		print("  LOD", lod, ": size=", lod_size, " subdivs=", lod_subdivs)

	# Store first material for camera updates
	if lod_meshes.size() > 0:
		terrain_material = lod_meshes[0].material_override

func create_collision():
	# Create static body for collision (only for center area)
	static_body = StaticBody3D.new()
	static_body.collision_layer = 1
	static_body.collision_mask = 0
	add_child(static_body)

	# Generate collision mesh from heightmap (smaller area for performance)
	var collision_mesh = generate_collision_mesh()

	collision_shape = CollisionShape3D.new()
	collision_shape.shape = collision_mesh
	static_body.add_child(collision_shape)

	print("✓ Collision mesh created (center area)")

func generate_collision_mesh() -> ConcavePolygonShape3D:
	"""Generate a collision mesh that matches the shader-displaced terrain"""
	var faces = PackedVector3Array()

	# Use smaller collision area for performance (center LOD only)
	var collision_size = base_mesh_size * 2.0
	var resolution = 32  # Lower resolution for collision
	var step = collision_size / float(resolution)
	var half_size = collision_size / 2.0

	# Generate vertices with height from noise
	var vertices = []
	for z in range(resolution + 1):
		var row = []
		for x in range(resolution + 1):
			var world_x = (x * step) - half_size
			var world_z = (z * step) - half_size

			# Sample noise at this position (matching shader)
			var height = get_height_at(world_x, world_z)

			row.append(Vector3(world_x, height, world_z))
		vertices.append(row)

	# Generate triangle faces
	for z in range(resolution):
		for x in range(resolution):
			var v0 = vertices[z][x]
			var v1 = vertices[z][x + 1]
			var v2 = vertices[z + 1][x]
			var v3 = vertices[z + 1][x + 1]

			# Triangle 1
			faces.append(v0)
			faces.append(v2)
			faces.append(v1)

			# Triangle 2
			faces.append(v1)
			faces.append(v2)
			faces.append(v3)

	var shape = ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape



func get_height_at(world_x: float, world_z: float) -> float:
	"""Get terrain height at world position (matching shader calculation)"""
	var uv_x = world_x * heightmap_scale
	var uv_z = world_z * heightmap_scale
	
	# Sample noise (this matches what the shader does)
	var height_value = noise.get_noise_2d(uv_x, uv_z)
	
	# Normalize from [-1, 1] to [0, 1]
	height_value = (height_value + 1.0) / 2.0
	
	# Apply height scale
	return height_value * max_height

func _process(_delta):
	# Don't run in editor
	if Engine.is_editor_hint():
		return

	# Only update terrain chunks when camera moves far enough
	if camera:
		var cam_pos = camera.global_position

		# Check if camera moved far enough to update chunks
		if cam_pos.distance_to(last_chunk_update_pos) > chunk_update_distance:
			print("Updating terrain chunks (camera moved", cam_pos.distance_to(last_chunk_update_pos), "m)")

			# Snap to chunk grid
			var snapped_pos = snap_to_chunk_grid(cam_pos)

			# Move all LOD meshes to new snapped position
			for mesh_instance in lod_meshes:
				if mesh_instance:
					mesh_instance.global_position = snapped_pos

			# Update collision
			if static_body:
				static_body.global_position = snapped_pos

			last_chunk_update_pos = cam_pos

			# Update model chunks when camera moves
			if model_amount > 0 and model_scenes.size() > 0:
				update_model_chunks()

func snap_to_chunk_grid(pos: Vector3) -> Vector3:
	"""Snap position to chunk grid to prevent constant regeneration"""
	var grid_size = chunk_update_distance
	return Vector3(
		floor(pos.x / grid_size) * grid_size,
		0,
		floor(pos.z / grid_size) * grid_size
	)

# ========== MODEL SPAWNING SYSTEM ==========

func update_model_chunks():
	"""Update model chunks based on camera position"""
	if not camera:
		return

	# Get valid model scenes
	var valid_scenes: Array[PackedScene] = []
	for scene in model_scenes:
		if scene != null:
			valid_scenes.append(scene)

	if valid_scenes.size() == 0:
		return

	var cam_pos = camera.global_position
	var camera_chunk = world_to_model_chunk(cam_pos)

	# Determine which chunks should have models (in a grid around camera)
	var chunk_radius = 3  # Load models 3 chunks in each direction
	var chunks_to_load = []

	for x in range(camera_chunk.x - chunk_radius, camera_chunk.x + chunk_radius + 1):
		for z in range(camera_chunk.y - chunk_radius, camera_chunk.y + chunk_radius + 1):
			var chunk_key = Vector2i(x, z)
			chunks_to_load.append(chunk_key)

			# Load chunk if not already loaded
			if not spawned_models.has(chunk_key):
				spawn_models_in_chunk(chunk_key, valid_scenes)

	# Unload distant chunks
	var chunks_to_unload = []
	for chunk_key in spawned_models.keys():
		if not chunks_to_load.has(chunk_key):
			chunks_to_unload.append(chunk_key)

	for chunk_key in chunks_to_unload:
		unload_chunk_models(chunk_key)

func world_to_model_chunk(pos: Vector3) -> Vector2i:
	"""Convert world position to model chunk coordinates"""
	return Vector2i(
		int(floor(pos.x / model_spawn_area_size)),
		int(floor(pos.z / model_spawn_area_size))
	)

func spawn_models_in_chunk(chunk_coords: Vector2i, valid_scenes: Array[PackedScene]):
	"""Spawn random models in a specific chunk"""
	var chunk_models = []
	var chunk_positions = []

	# Calculate chunk world position
	var chunk_world_x = chunk_coords.x * model_spawn_area_size
	var chunk_world_z = chunk_coords.y * model_spawn_area_size

	# Random number of models for this chunk
	var num_models = randi_range(models_per_chunk_min, models_per_chunk_max)

	var spawned_count = 0
	var max_attempts = num_models * 10
	var attempts = 0

	while spawned_count < num_models and attempts < max_attempts:
		attempts += 1

		# Random position within this chunk
		var local_x = randf() * model_spawn_area_size
		var local_z = randf() * model_spawn_area_size
		var world_x = chunk_world_x + local_x
		var world_z = chunk_world_z + local_z

		# Get terrain height
		var height = get_height_at(world_x, world_z)
		var spawn_pos = Vector3(world_x, height, world_z)

		# Check if valid position (not too close to other models in this chunk)
		if is_valid_position_in_chunk(spawn_pos, chunk_positions):
			# Pick random model
			var model_scene = valid_scenes[randi() % valid_scenes.size()]

			# Spawn it
			var model_instance = spawn_model_at_position(model_scene, spawn_pos)
			if model_instance:
				chunk_models.append(model_instance)
				chunk_positions.append(spawn_pos)
				spawned_count += 1

	# Store chunk data
	spawned_models[chunk_coords] = chunk_models
	chunk_model_positions[chunk_coords] = chunk_positions

func is_valid_position_in_chunk(pos: Vector3, existing_positions: Array) -> bool:
	"""Check if position is valid within a chunk"""
	for existing_pos in existing_positions:
		if pos.distance_to(existing_pos) < model_min_distance:
			return false
	return true

func unload_chunk_models(chunk_coords: Vector2i):
	"""Remove all models from a chunk"""
	if spawned_models.has(chunk_coords):
		for model in spawned_models[chunk_coords]:
			if model and is_instance_valid(model):
				model.queue_free()

		spawned_models.erase(chunk_coords)
		chunk_model_positions.erase(chunk_coords)

func spawn_model_at_position(model_scene: PackedScene, position: Vector3) -> Node3D:
	"""Instantiate and spawn a model at the given position"""
	if not model_scene:
		return null

	# Instantiate the model
	var model_instance: Node3D = model_scene.instantiate()

	if not model_instance:
		return null

	# Set position
	model_instance.global_position = position

	# Apply random rotation (Y-axis only for natural placement)
	model_instance.rotation.y = randf() * TAU

	# Apply random scale if configured
	if model_scale_min != model_scale_max:
		var random_scale = randf_range(model_scale_min, model_scale_max)
		model_instance.scale = Vector3(random_scale, random_scale, random_scale)
	elif model_scale_min != 1.0:
		model_instance.scale = Vector3(model_scale_min, model_scale_min, model_scale_min)

	# Add to scene
	add_child(model_instance)

	return model_instance

func clear_all_models():
	"""Remove all spawned models from all chunks"""
	for chunk_key in spawned_models.keys():
		unload_chunk_models(chunk_key)
