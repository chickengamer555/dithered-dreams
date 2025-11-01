extends Node2D

@export var main_menu_scene: PackedScene
var text_to_type_1 = "It was all a dream"
var text_to_type_2 = "or was it?"
var typing_speed = 0.1  # seconds per character
var current_text = ""

func _ready():
	# Start typing the first line immediately when the scene is loaded
	start_typing(text_to_type_1)

func start_typing(text: String) -> void:
	typing_coroutine(text)

func typing_coroutine(text: String) -> void:
	current_text = ""
	var label = $CanvasLayer/TypingLabel
	for char in text:
		current_text += char
		label.text = current_text
		await get_tree().create_timer(typing_speed).timeout
	
	if text == text_to_type_1:
		# Finished typing the first text ("It was all a dream")
		# Wait 1 second, then play the transition before typing "or was it?"
		await get_tree().create_timer(1.0).timeout
		play_transition_effect(Callable(self, "_type_second_line"))
	elif text == text_to_type_2:
		# Finished typing the second text ("or was it?")
		# Wait 2 seconds, then go to main menu
		await get_tree().create_timer(2.0).timeout
		go_to_main_menu()

func _type_second_line():
	# This function is called after the transition finishes
	start_typing(text_to_type_2)

func go_to_main_menu():
	if main_menu_scene:
		var menu = main_menu_scene.instantiate()
		get_tree().root.add_child(menu)
		get_tree().current_scene.queue_free()
	else:
		print("Error: Main menu scene not set in Jumpscare.")

func play_transition_effect(completion_callback: Callable):
	var transition_rect = $CanvasLayer/TransitionRect
	if transition_rect:
		transition_rect.visible = true
		transition_rect.modulate.a = 0.0  # Start transparent
		var tween = create_tween()
		# Fade in
		tween.tween_property(transition_rect, "modulate:a", 1.0, 0.1)
		# After fade-in, call the completion_callback
		tween.tween_callback(completion_callback)
		# Fade out
		tween.tween_property(transition_rect, "modulate:a", 0.0, 0.5)
		# After fade-out, hide the transition_rect
		tween.tween_callback(Callable(self, "_hide_transition_rect"))

func _hide_transition_rect():
	var transition_rect = $CanvasLayer/TransitionRect
	if transition_rect:
		transition_rect.visible = false
