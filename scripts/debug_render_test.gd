extends Node3D

# Test if ANY 3D shapes render as solid

func _ready():
	print("=== RENDER DEBUG TEST ===")
	print("Testing if 3D objects render as solid or wireframe...")

	# Test 1: Create a simple cube
	create_test_cube()

	# Test 2: Create procedural mesh
	create_procedural_plane()

	print("✓ Objects created. Check if they appear solid or as wireframe.")
	print("If wireframe: Rendering/Graphics driver issue")
	print("If solid: Mesh generation issue")

func create_test_cube():
	# Create a simple CSGBox3D to test rendering
	var box = CSGBox3D.new()
	box.size = Vector3(10, 10, 10)
	box.position = Vector3(-20, 5, 0)

	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1, 0, 0)  # Red
	box.material = material

	add_child(box)
	print("✓ Test cube created at (-20, 5, 0) - should be RED")

func create_procedural_plane():
	# Simple quad (2 triangles)
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)

	var vertices = PackedVector3Array([
		Vector3(-5, 0, -5),
		Vector3(5, 0, -5),
		Vector3(5, 0, 5),
		Vector3(-5, 0, 5)
	])

	var indices = PackedInt32Array([
		0, 1, 2,  # First triangle
		0, 2, 3   # Second triangle
	])

	var normals = PackedVector3Array([
		Vector3.UP,
		Vector3.UP,
		Vector3.UP,
		Vector3.UP
	])

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.position = Vector3(20, 0, 0)

	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0, 0, 1)  # Blue
	mesh_instance.set_surface_override_material(0, material)

	add_child(mesh_instance)
	print("✓ Procedural quad created at (20, 0, 0) - should be BLUE")
