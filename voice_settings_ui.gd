extends Control

## Voice Settings UI
## Provides instructions for configuring microphone in Steam

@onready var close_button: Button = $Panel/VBoxContainer/CloseButton
@onready var open_steam_settings_button: Button = $Panel/VBoxContainer/OpenSteamSettingsButton

func _ready():
	# Connect buttons
	close_button.pressed.connect(_on_close_pressed)
	open_steam_settings_button.pressed.connect(_on_open_steam_settings_pressed)
	
	# Hide by default
	hide()

func _on_close_pressed():
	hide()

func _on_open_steam_settings_pressed():
	# Open Steam settings overlay
	Steam.activateGameOverlayToWebPage("steam://settings/voice")
	hide()

func show_settings():
	show()

