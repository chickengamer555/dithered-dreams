extends Control

# Audio bus indices
const BUS_MASTER = 0
const BUS_MUSIC = 1
const BUS_SFX = 2
const BUS_VOICES = 3

# UI References
@onready var music_slider = $VBoxContainer/MusicContainer/MusicSlider
@onready var sfx_slider = $VBoxContainer/SFXContainer/SFXSlider
@onready var voices_slider = $VBoxContainer/VoicesContainer/VoicesSlider
@onready var music_value_label = $VBoxContainer/MusicContainer/ValueLabel
@onready var sfx_value_label = $VBoxContainer/SFXContainer/ValueLabel
@onready var voices_value_label = $VBoxContainer/VoicesContainer/ValueLabel
@onready var back_button = $VBoxContainer/BackButton

func _ready():
	# Load saved settings
	load_settings()

	# Connect slider signals
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	voices_slider.value_changed.connect(_on_voices_changed)
	back_button.pressed.connect(_on_back_pressed)

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

func _on_back_pressed():
	# Return to main menu
	get_tree().change_scene_to_file("res://main_menu.tscn")
