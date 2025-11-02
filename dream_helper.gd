extends Area3D

# Dream Helper - Collectible item that reduces nightmare

@export var nightmare_reduction_min: float = 5.0  # Minimum % to reduce
@export var nightmare_reduction_max: float = 20.0  # Maximum % to reduce
@export var rotation_speed: float = 1.0  # How fast the item rotates

# Reference to the world script
var world_script: Node = null

# Visual feedback
var mesh_instance: MeshInstance3D = null

# Track if already collected (prevent double collection)
var collected: bool = false

func _ready():
	# Connect signals
	body_entered.connect(_on_body_entered)

	# Find the world script
	world_script = get_tree().root.get_node_or_null("world")
	if not world_script:
		print("ERROR: Could not find world script!")

	# Get mesh instance for rotation
	mesh_instance = get_node_or_null("MeshInstance3D")

func _process(delta: float) -> void:
	# Rotate the item for visual effect
	if mesh_instance:
		mesh_instance.rotate_y(rotation_speed * delta)

func _on_body_entered(body: Node3D) -> void:
	# Auto-collect when player touches it
	if collected:
		return

	# Check if it's a player (has is_multiplayer_authority method or is the single player)
	var is_player = false
	if body.has_method("is_multiplayer_authority"):
		is_player = body.is_multiplayer_authority()
	elif body.name == "Player":
		is_player = true

	if is_player:
		_collect_item()

func _collect_item() -> void:
	if collected or not world_script:
		return

	collected = true
	print("Dream Helper collected!")

	# Calculate random reduction amount
	var reduction = randf_range(nightmare_reduction_min, nightmare_reduction_max)

	# Tell the world script to reduce nightmare
	if world_script.has_method("reduce_nightmare_from_item"):
		world_script.reduce_nightmare_from_item(reduction)

	# Remove the item from the world
	queue_free()

