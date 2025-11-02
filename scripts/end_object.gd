extends Area3D

# This is the "sleep" object that players interact with to teleport to a different dream world

@export var interaction_distance: float = 3.0
@export var hold_time: float = 2.0  # How long to hold mouse to activate

# Track ALL players in range (for multiplayer requirement)
var players_in_range: Array = []
var local_player_in_range: bool = false
var is_holding: bool = false
var hold_progress: float = 0.0

# Reference to the world script
var world_script: Node = null

func _ready():
	# Connect signals
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	# Find the world script
	world_script = get_tree().root.get_node_or_null("world")
	if not world_script:
		print("ERROR: Could not find world script!")

func _process(delta: float) -> void:
	# Only the local player can interact
	if local_player_in_range:
		# Check if all players are in range (for multiplayer)
		var all_players_ready = _check_all_players_in_range()

		if not all_players_ready:
			# Show "waiting for other players" message
			if is_holding:
				is_holding = false
				hold_progress = 0.0
				_update_interaction_ui(0.0)
			return

		# Check if mouse button is held down
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if not is_holding:
				is_holding = true
				hold_progress = 0.0

			# Increase hold progress
			hold_progress += delta

			# Update UI to show progress
			_update_interaction_ui(hold_progress / hold_time)

			# Check if held long enough
			if hold_progress >= hold_time:
				_activate_teleport()
				is_holding = false
				hold_progress = 0.0
		else:
			# Reset if button released
			if is_holding:
				is_holding = false
				hold_progress = 0.0
				_update_interaction_ui(0.0)

func _on_body_entered(body: Node3D) -> void:
	# Check if it's a player
	if body is CharacterBody3D and body.has_method("is_multiplayer_authority"):
		# Add to players in range list
		if not players_in_range.has(body):
			players_in_range.append(body)
			print("Player ", body.name, " entered end object range (", players_in_range.size(), " total)")

		# Track if local player entered
		if body.is_multiplayer_authority():
			local_player_in_range = true
			_update_prompt_message()

func _on_body_exited(body: Node3D) -> void:
	# Remove from players in range list
	if players_in_range.has(body):
		players_in_range.erase(body)
		print("Player ", body.name, " exited end object range (", players_in_range.size(), " remaining)")

	# Track if local player exited
	if body.has_method("is_multiplayer_authority") and body.is_multiplayer_authority():
		local_player_in_range = false
		is_holding = false
		hold_progress = 0.0
		_hide_interaction_prompt()

func _show_interaction_prompt(text: String) -> void:
	# Tell the world script to show interaction UI with custom text
	if world_script and world_script.has_method("show_interaction_prompt"):
		world_script.show_interaction_prompt(text)

func _hide_interaction_prompt() -> void:
	# Tell the world script to hide the UI
	if world_script and world_script.has_method("hide_interaction_prompt"):
		world_script.hide_interaction_prompt()

func _update_interaction_ui(progress: float) -> void:
	# Update the progress bar/visual feedback
	if world_script and world_script.has_method("update_interaction_progress"):
		world_script.update_interaction_progress(progress)

func _check_all_players_in_range() -> bool:
	# Get total player count from world script
	if not world_script:
		return true  # Single player, always ready

	var total_players = 1  # Default to single player
	if world_script.has_method("get_total_player_count"):
		total_players = world_script.get_total_player_count()

	# Check if all players are in range
	var all_ready = players_in_range.size() >= total_players

	# Update prompt based on status
	if local_player_in_range:
		_update_prompt_message()

	return all_ready

func _update_prompt_message() -> void:
	if not world_script:
		return

	var total_players = 1
	if world_script.has_method("get_total_player_count"):
		total_players = world_script.get_total_player_count()

	if players_in_range.size() >= total_players:
		# All players ready!
		_show_interaction_prompt("Hold mouse to sleep")
	else:
		# Waiting for other players
		var waiting_count = total_players - players_in_range.size()
		_show_interaction_prompt("Waiting for " + str(waiting_count) + " player(s) to come to bed...")

func _activate_teleport() -> void:
	print("End object activated! Teleporting to random dream world...")

	# Hide UI
	_hide_interaction_prompt()

	# Tell the world script to teleport
	if world_script and world_script.has_method("teleport_from_end_object"):
		world_script.teleport_from_end_object()
