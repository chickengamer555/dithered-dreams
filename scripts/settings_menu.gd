extends Control

# Audio bus indices
const BUS_MASTER = 0
const BUS_MUSIC = 1
const BUS_SFX = 2
const BUS_VOICES = 3

# Track if we're opened as an overlay (from in-game) or as a scene change (from main menu)
var is_overlay: bool = false

# UI References
@onready var music_slider = $VBoxContainer/MusicContainer/MusicSlider
@onready var sfx_slider = $VBoxContainer/SFXContainer/SFXSlider
@onready var voices_slider = $VBoxContainer/VoicesContainer/VoicesSlider
@onready var music_value_label = $VBoxContainer/MusicContainer/ValueLabel
@onready var sfx_value_label = $VBoxContainer/SFXContainer/ValueLabel
@onready var voices_value_label = $VBoxContainer/VoicesContainer/ValueLabel
@onready var leave_game_button = $VBoxContainer/LeaveGameButton
@onready var back_button = $VBoxContainer/BackButton

func _ready():
	# Detect if we're an overlay (parent is CanvasLayer) or a scene change (parent is root)
	# When opened from in-game via ESC, we're added to world's CanvasLayer
	# When opened from main menu, we're the root scene
	is_overlay = get_parent() is CanvasLayer

	# Load saved settings
	load_settings()

	# Connect slider signals
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	voices_slider.value_changed.connect(_on_voices_changed)
	leave_game_button.pressed.connect(_on_leave_game_pressed)
	back_button.pressed.connect(_on_back_pressed)

	# Only show leave game button when in-game (overlay mode)
	if not is_overlay:
		leave_game_button.visible = false

func _input(event):
	# Close settings menu with ESC key
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if is_overlay:
			_on_back_pressed()
			get_viewport().set_input_as_handled()  # Prevent ESC from propagating

func load_settings():
	# Load from config file or use defaults
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")

	if err == OK:
		music_slider.value = config.get_value("audio", "music_volume", 100)
		sfx_slider.value = config.get_value("audio", "sfx_volume", 100)
		voices_slider.value = config.get_value("audio", "voices_volume", 100)
	else:
		# Defaults (100%)
		music_slider.value = 100
		sfx_slider.value = 100
		voices_slider.value = 100

	# Apply settings and update labels
	apply_audio_settings()
	update_value_labels()

func save_settings():
	var config = ConfigFile.new()
	config.set_value("audio", "music_volume", music_slider.value)
	config.set_value("audio", "sfx_volume", sfx_slider.value)
	config.set_value("audio", "voices_volume", voices_slider.value)
	config.save("user://settings.cfg")

func apply_audio_settings():
	# Convert percentage (0-100) to decibels
	# 0% = -80 dB (effectively silent)
	# 100% = 0 dB (full volume)
	set_bus_volume(BUS_MUSIC, music_slider.value)
	set_bus_volume(BUS_SFX, sfx_slider.value)
	set_bus_volume(BUS_VOICES, voices_slider.value)

func set_bus_volume(bus_index: int, volume_percent: float):
	if volume_percent <= 0:
		AudioServer.set_bus_mute(bus_index, true)
	else:
		AudioServer.set_bus_mute(bus_index, false)
		# Convert percentage to decibels with a better curve
		# 0% = -40 dB (very quiet but not silent)
		# 50% = -12 dB (half perceived loudness)
		# 100% = 0 dB (full volume)
		# Use logarithmic scale for natural volume perception
		var normalized = volume_percent / 100.0
		var db = -40 + (40 * normalized * normalized)  # Quadratic curve for better response
		AudioServer.set_bus_volume_db(bus_index, db)

func update_value_labels():
	music_value_label.text = str(int(music_slider.value)) + "%"
	sfx_value_label.text = str(int(sfx_slider.value)) + "%"
	voices_value_label.text = str(int(voices_slider.value)) + "%"

func _on_music_changed(value: float):
	set_bus_volume(BUS_MUSIC, value)
	music_value_label.text = str(int(value)) + "%"
	save_settings()

func _on_sfx_changed(value: float):
	set_bus_volume(BUS_SFX, value)
	sfx_value_label.text = str(int(value)) + "%"
	save_settings()

func _on_voices_changed(value: float):
	set_bus_volume(BUS_VOICES, value)
	voices_value_label.text = str(int(value)) + "%"
	save_settings()

func _on_leave_game_pressed():
	"""Leave the current game and return to main menu"""
	print("[Settings] Leave game button pressed")

	# Get reference to world script
	if get_parent() is CanvasLayer:
		var world = get_parent().get_parent()
		if world and world.has_method("leave_game"):
			world.leave_game()
		else:
			# Fallback: just go to main menu
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_back_pressed():
	if is_overlay:
		# We're an overlay (from in-game or from main menu), just close
		# Notify world that we're closing if we're in-game
		if get_parent() is CanvasLayer:
			var world = get_parent().get_parent()
			if world and world.has_method("close_settings_menu"):
				world.close_settings_menu()
				return  # World will handle cleanup
		# Game stays unpaused - no pause/unpause logic needed
		queue_free()
	else:
		# We're a scene change (shouldn't happen anymore, but keep for safety)
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
