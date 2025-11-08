extends Node3D

## Helper class to visualize pathfinding grid
## This creates permanent debug geometry to see the grid

var immediate_mesh: ImmediateMesh = null
var mesh_instance: MeshInstance3D = null
var material_valid: StandardMaterial3D = null
var material_blocked: StandardMaterial3D = null
var material_point: StandardMaterial3D = null

func _ready():
	# Create materials
	material_valid = StandardMaterial3D.new()
	material_valid.albedo_color = Color(0, 1, 0, 0.3)  # Green for valid connections
	material_valid.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material_valid.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	material_blocked = StandardMaterial3D.new()
	material_blocked.albedo_color = Color(1, 0, 0, 0.8)  # Red for blocked connections
	material_blocked.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material_blocked.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	material_point = StandardMaterial3D.new()
	material_point.albedo_color = Color(0, 0.5, 1, 1)  # Blue for grid points
	material_point.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

func draw_grid(astar: AStar3D, point_positions: Dictionary, blocked_connections: Array):
	"""Draw the entire pathfinding grid"""
	print("🎨 Drawing pathfinding grid visualization...")

	# Draw all grid points as small spheres
	for point_id in point_positions:
		var pos = point_positions[point_id]
		_draw_sphere(pos, 0.15, material_point)

	# Draw valid connections (green lines)
	var drawn_connections = {}
	for point_id in point_positions:
		var connected_ids = astar.get_point_connections(point_id)
		for connected_id in connected_ids:
			# Avoid drawing same connection twice
			var key = str(min(point_id, connected_id)) + "_" + str(max(point_id, connected_id))
			if not drawn_connections.has(key):
				drawn_connections[key] = true
				var from_pos = point_positions[point_id]
				var to_pos = point_positions[connected_id]
				_draw_line(from_pos, to_pos, material_valid)

	# Draw blocked connections (red lines)
	for connection in blocked_connections:
		_draw_line(connection[0], connection[1], material_blocked)

	print("✅ Grid visualization complete")

func _draw_line(from: Vector3, to: Vector3, material: Material):
	"""Draw a 3D line"""
	var mesh_inst = MeshInstance3D.new()
	var imm_mesh = ImmediateMesh.new()

	mesh_inst.mesh = imm_mesh
	mesh_inst.material_override = material

	imm_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	imm_mesh.surface_add_vertex(from + Vector3(0, 0.1, 0))  # Raise slightly above ground
	imm_mesh.surface_add_vertex(to + Vector3(0, 0.1, 0))
	imm_mesh.surface_end()

	add_child(mesh_inst)

func _draw_sphere(position: Vector3, radius: float, material: Material):
	"""Draw a small sphere at position"""
	var mesh_inst = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0

	mesh_inst.mesh = sphere
	mesh_inst.material_override = material
	mesh_inst.position = position + Vector3(0, 0.2, 0)  # Raise above ground

	add_child(mesh_inst)
