extends Node3D
class_name PlayerSpawnPoint

# Simple marker for where players can spawn
# Just needs to exist in the world with a position

func _ready():
	# Hide any visual representation in game (only show in editor)
	if not Engine.is_editor_hint():
		# Make invisible but keep the node active for position reference
		visible = false

