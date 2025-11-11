extends Area3D

# Nightmare Helper - Collectible item that increases nightmare

@export var nightmare_increase_min: float = 5.0  # Minimum % to increase
@export var nightmare_increase_max: float = 20.0  # Maximum % to increase
@export var rotation_speed: float = 1.0  # How fast the item rotates

# Reference to the world script
var world_script: Node = null

# Visual feedback
var mesh_instance: MeshInstance3D = null

# Track if already collected (prevent double collection)
var collected: bool = false

func _ready():
	print("🔴 NIGHTMARE HELPER SPAWNED at position: ", global_position)
	print("🔴 Nightmare Helper name: ", name)
	print("🔴 Nightmare Helper parent: ", get_parent().name if get_parent() else "NO PARENT")

	# Connect signals
	body_entered.connect(_on_body_entered)

	# Find the world script
	world_script = get_tree().root.get_node_or_null("world")
	if not world_script:
		print("ERROR: Could not find world script!")
	else:
		print("🔴 Nightmare Helper found world script successfully")

	# Get mesh instance for rotation
	mesh_instance = get_node_or_null("MeshInstance3D")
	if mesh_instance:
		print("🔴 Nightmare Helper mesh instance found")
		print("🔴   Mesh visible: ", mesh_instance.visible)
		print("🔴   Mesh layers: ", mesh_instance.layers)
		print("🔴   Mesh cast_shadow: ", mesh_instance.cast_shadow)
		print("🔴   Mesh material: ", mesh_instance.get_surface_override_material(0))
		print("🔴   Mesh mesh: ", mesh_instance.mesh)
		if mesh_instance.mesh:
			print("🔴   Mesh surface count: ", mesh_instance.mesh.get_surface_count())
			if mesh_instance.mesh.get_surface_count() > 0:
				var mat = mesh_instance.mesh.surface_get_material(0)
				print("🔴   Mesh surface material: ", mat)
				if mat is StandardMaterial3D:
					print("🔴   Material albedo: ", mat.albedo_color)
					print("🔴   Material emission_enabled: ", mat.emission_enabled)
					print("🔴   Material emission: ", mat.emission)
					print("🔴   Material emission_energy: ", mat.emission_energy_multiplier)

		# FORCE VISIBILITY REFRESH - Fix for spawning in disabled world
		mesh_instance.visible = false
		await get_tree().process_frame
		mesh_instance.visible = true
		print("🔴 FORCED MESH VISIBILITY REFRESH")
	else:
		print("ERROR: Nightmare Helper mesh instance NOT found!")

func _process(delta: float) -> void:
	# Rotate the item for visual effect
	if mesh_instance:
		mesh_instance.rotate_y(rotation_speed * delta)

func _on_body_entered(body: Node3D) -> void:
	print("🔴 NIGHTMARE HELPER: Body entered - ", body.name)

	# Auto-collect when player touches it
	if collected:
		print("🔴 NIGHTMARE HELPER: Already collected, ignoring")
		return

	# Check if it's a player (has is_multiplayer_authority method or is the single player)
	var is_player = false
	if body.has_method("is_multiplayer_authority"):
		is_player = body.is_multiplayer_authority()
	elif body.name == "Player":
		is_player = true

	print("🔴 NIGHTMARE HELPER: Is player? ", is_player)

	if is_player:
		_collect_item()

func _collect_item() -> void:
	print("🔴 NIGHTMARE HELPER: _collect_item called")

	if collected or not world_script:
		print("🔴 NIGHTMARE HELPER: Already collected or no world script")
		return

	collected = true
	print("🔴 ========================================")
	print("🔴 NIGHTMARE HELPER COLLECTED!")
	print("🔴 ========================================")

	# Calculate random increase amount
	var increase = randf_range(nightmare_increase_min, nightmare_increase_max)
	print("🔴 Nightmare increase amount: ", increase, "%")

	# Tell the world script to increase nightmare
	if world_script.has_method("increase_nightmare_from_item"):
		print("🔴 Calling increase_nightmare_from_item on world script")
		world_script.increase_nightmare_from_item(increase)
	else:
		print("ERROR: world_script does not have increase_nightmare_from_item method!")

	# Remove the item from the world
	print("🔴 Removing nightmare helper from world")
	queue_free()
