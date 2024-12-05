extends Control

@onready var start_button = $Button  # Reference to the Start button

var world_scene: PackedScene = load("res://world.tscn")  # Load world scene

func _on_startbutton_pressed() -> void:
	if world_scene:
		# Create an instance of the world scene
		var world = world_scene.instantiate()
		get_tree().root.add_child(world)  # Add the world to the scene tree
		queue_free()  # Remove the main menu
		print("World started!")
	else:
		print("World scene not assigned!")  # Debugging
