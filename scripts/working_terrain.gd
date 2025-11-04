extends MeshInstance3D

## WORKING TERRAIN GENERATOR - Uses PlaneMesh (guaranteed solid rendering)

@export var terrain_width: float = 100.0
@export var terrain_depth: float = 100.0
@export var subdivisions: int = 50  # Higher = more detail
@export var terrain_height: float = 15.0
@export var noise_scale: float = 0.05

func _ready():
	print("=== WORKING TERRAIN GENERATOR ===")
	generate_terrain()
	print("✓ Terrain generated successfully!")

func generate_terrain():
	# Step 1: Create a PlaneMesh (this WILL render solid - it's a built-in Godot primitive)
	var plane_mesh = PlaneMesh.new()
	plane_mesh.size = Vector2(terrain_width, terrain_depth)
	plane_mesh.subdivide_width = subdivisions
	plane_mesh.subdivide_depth = subdivisions

	# Step 2: Convert to ArrayMesh so we can modify vertices
	var surface_tool = SurfaceTool.new()
	surface_tool.create_from(plane_mesh, 0)
	var array_mesh = surface_tool.commit()

	# Step 3: Use MeshDataTool to access and modify vertices
	var mdt = MeshDataTool.new()
	mdt.create_from_surface(array_mesh, 0)

	# Step 4: Apply procedural heights using noise
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = noise_scale
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_octaves = 4

	for i in range(mdt.get_vertex_count()):
		var vertex = mdt.get_vertex(i)

		# Generate height from noise
		var height = noise.get_noise_2d(vertex.x, vertex.z) * terrain_height

		# Apply height
		vertex.y = height
		mdt.set_vertex(i, vertex)

	# Step 5: Commit modified vertices back to mesh
	array_mesh.clear_surfaces()
	mdt.commit_to_surface(array_mesh)

	# Step 6: Regenerate normals for proper lighting
	surface_tool.clear()
	surface_tool.create_from(array_mesh, 0)
	surface_tool.generate_normals()
	array_mesh = surface_tool.commit()

	# Step 7: Apply mesh to this MeshInstance3D
	mesh = array_mesh

	# Step 8: Create liminal/horror material
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.27, 0.24)  # Murky gray-green, desaturated
	material.roughness = 0.95  # Very matte, no shine
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_BACK
	# Add slight emission for eerie atmosphere
	material.emission_enabled = true
	material.emission = Color(0.15, 0.16, 0.15) * 0.02
	set_surface_override_material(0, material)

	# Step 9: Add collision
	create_trimesh_collision()

	print("  Vertices: ", mdt.get_vertex_count())
	print("  Faces: ", mdt.get_face_count())
	print("  Size: ", terrain_width, "x", terrain_depth)
