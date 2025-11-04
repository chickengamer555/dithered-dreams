extends Node3D

# Chunk settings
const CHUNK_SIZE = 64  # Size of each chunk in units
const CHUNK_RESOLUTION = 32  # Vertices per chunk (32x32 = good performance)
const RENDER_DISTANCE = 4  # Chunks visible in each direction
const COLLISION_DISTANCE = 2  # Only add collision to nearby chunks

# Terrain parameters
@export var max_height: float = 20.0
@export var noise_seed: int = 0
@export var noise_frequency: float = 0.008
@export var noise_octaves: int = 5

# Storage
var chunks = {}
var noise: FastNoiseLite
var camera: Camera3D

func _ready():
	setup_noise()

	# Wait a frame for camera to be ready
	await get_tree().process_frame
	camera = get_node_or_null("../FreeFlyCamera")

	if not camera:
		print("WARNING: FreeFlyCamera not found for procedural terrain")
		return

	print("=== PROCEDURAL TERRAIN INITIALIZED ===")
	print("Chunk size: ", CHUNK_SIZE, " units")
	print("Resolution: ", CHUNK_RESOLUTION, "x", CHUNK_RESOLUTION, " vertices per chunk")
	print("Render distance: ", RENDER_DISTANCE, " chunks")
	print("Noise seed: ", noise_seed)
	print("======================================")

	# Generate initial chunks around camera
	update_chunks()

func setup_noise():
	if noise_seed == 0:
		noise_seed = randi()

	noise = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = noise_frequency
	noise.fractal_octaves = noise_octaves
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.0

func _process(_delta):
	if not camera:
		return

	update_chunks()

func update_chunks():
	var camera_chunk = world_to_chunk(camera.global_position)

	# Load chunks in render distance
	for x in range(camera_chunk.x - RENDER_DISTANCE, camera_chunk.x + RENDER_DISTANCE + 1):
		for z in range(camera_chunk.y - RENDER_DISTANCE, camera_chunk.y + RENDER_DISTANCE + 1):
			var chunk_key = Vector2i(x, z)

			if not chunks.has(chunk_key):
				load_chunk(chunk_key)

	# Unload distant chunks
	var to_unload = []
	for chunk_key in chunks.keys():
		if chunk_key.distance_to(camera_chunk) > RENDER_DISTANCE + 1:
			to_unload.append(chunk_key)

	for chunk_key in to_unload:
		unload_chunk(chunk_key)

func world_to_chunk(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / CHUNK_SIZE)),
		int(floor(pos.z / CHUNK_SIZE))
	)

func load_chunk(chunk_coords: Vector2i):
	var mesh_instance = generate_chunk_mesh(chunk_coords)
	chunks[chunk_coords] = mesh_instance
	add_child(mesh_instance)
	print("Loaded chunk: ", chunk_coords)

func unload_chunk(chunk_coords: Vector2i):
	if chunks.has(chunk_coords):
		chunks[chunk_coords].queue_free()
		chunks.erase(chunk_coords)

func generate_chunk_mesh(chunk_coords: Vector2i) -> MeshInstance3D:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var offset_x = chunk_coords.x * CHUNK_SIZE
	var offset_z = chunk_coords.y * CHUNK_SIZE

	# Generate vertices in LOCAL space
	for z in range(CHUNK_RESOLUTION + 1):
		for x in range(CHUNK_RESOLUTION + 1):
			# Local position within this chunk (0 to CHUNK_SIZE)
			var local_x = (float(x) / CHUNK_RESOLUTION) * CHUNK_SIZE
			var local_z = (float(z) / CHUNK_RESOLUTION) * CHUNK_SIZE

			# World position for noise sampling
			var world_x = offset_x + local_x
			var world_z = offset_z + local_z

			var height = get_height(world_x, world_z)

			# UV coordinates for texturing
			st.set_uv(Vector2(float(x) / CHUNK_RESOLUTION, float(z) / CHUNK_RESOLUTION))
			# Add vertex in LOCAL space
			st.add_vertex(Vector3(local_x, height, local_z))

	# Generate triangle indices
	for z in range(CHUNK_RESOLUTION):
		for x in range(CHUNK_RESOLUTION):
			var i = z * (CHUNK_RESOLUTION + 1) + x

			# First triangle
			st.add_index(i)
			st.add_index(i + CHUNK_RESOLUTION + 1)
			st.add_index(i + 1)

			# Second triangle
			st.add_index(i + 1)
			st.add_index(i + CHUNK_RESOLUTION + 1)
			st.add_index(i + CHUNK_RESOLUTION + 2)

	# Generate normals for lighting
	st.generate_normals()

	# Commit the mesh
	var mesh = st.commit()
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh

	# CRITICAL: Position the mesh instance in world space
	mesh_instance.position = Vector3(offset_x, 0, offset_z)
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Add collision only to nearby chunks for performance
	var chunk_center = Vector3(
		offset_x + CHUNK_SIZE / 2,
		0,
		offset_z + CHUNK_SIZE / 2
	)

	if camera and camera.global_position.distance_to(chunk_center) < CHUNK_SIZE * COLLISION_DISTANCE:
		mesh_instance.create_trimesh_collision()

	# Create liminal/horror material - desaturated, eerie
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.27, 0.24)  # Murky gray-green, desaturated
	material.roughness = 0.95  # Very matte
	material.metallic = 0.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	# Add slight emission for eerie glow
	material.emission_enabled = true
	material.emission = Color(0.15, 0.16, 0.15) * 0.02
	mesh_instance.set_surface_override_material(0, material)

	return mesh_instance

func get_height(x: float, z: float) -> float:
	# Get base terrain height
	var noise_value = noise.get_noise_2d(x, z)
	var base_height = (noise_value + 1.0) / 2.0 * max_height

	# Add some rolling hills with different frequency
	var hills = noise.get_noise_2d(x * 0.3, z * 0.3)
	var hill_height = (hills + 1.0) / 2.0 * (max_height * 0.3)

	return base_height + hill_height
