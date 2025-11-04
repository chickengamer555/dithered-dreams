extends Node3D

# Simple single-chunk terrain test

func _ready():
	print("=== SIMPLE TERRAIN TEST ===")
	generate_test_terrain()
	print("Terrain generated! You should see a green mesh.")

func generate_test_terrain():
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var size = 100.0
	var resolution = 20

	# Generate vertices
	for z in range(resolution + 1):
		for x in range(resolution + 1):
			var px = (float(x) / resolution) * size - size / 2
			var pz = (float(z) / resolution) * size - size / 2

			# Simple sine wave height
			var height = sin(px * 0.1) * cos(pz * 0.1) * 10.0

			st.set_uv(Vector2(float(x) / resolution, float(z) / resolution))
			st.add_vertex(Vector3(px, height, pz))

	# Generate triangles
	for z in range(resolution):
		for x in range(resolution):
			var i = z * (resolution + 1) + x

			# Triangle 1
			st.add_index(i)
			st.add_index(i + resolution + 1)
			st.add_index(i + 1)

			# Triangle 2
			st.add_index(i + 1)
			st.add_index(i + resolution + 1)
			st.add_index(i + resolution + 2)

	st.generate_normals()

	var mesh = st.commit()
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh

	# Create liminal/horror material
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.27, 0.24)  # Murky gray-green
	material.roughness = 0.95  # Very matte
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Show both sides for debugging
	# Add slight emission for eerie glow
	material.emission_enabled = true
	material.emission = Color(0.15, 0.16, 0.15) * 0.02
	mesh_instance.set_surface_override_material(0, material)

	add_child(mesh_instance)

	print("✓ Mesh created with ", (resolution + 1) * (resolution + 1), " vertices")
	print("✓ Material: Bright green, both sides visible")
