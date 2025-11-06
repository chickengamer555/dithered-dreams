extends Control

# Dev Terminal - Debug console for testing commands

@onready var output_label: RichTextLabel = $Panel/VBoxContainer/OutputScroll/OutputLabel
@onready var input_field: LineEdit = $Panel/VBoxContainer/InputField
@onready var panel: Panel = $Panel

# Reference to the world script
var world_script: Node = null

# Command history
var command_history: Array[String] = []
var history_index: int = -1

# Output buffer
var output_lines: Array[String] = []
const MAX_OUTPUT_LINES: int = 20

func _ready():
	# Hide terminal by default
	visible = false

	# Connect input field signals
	input_field.text_submitted.connect(_on_input_submitted)

	# Get reference to world script
	world_script = get_node("/root/world")
	if not world_script:
		print("ERROR: Dev terminal could not find world script!")

	# Add welcome message (no instructions - user must type /help)
	add_output("[color=cyan]Dev Terminal Ready[/color]")
	add_output("Type /help for commands")
	add_output("")

func _input(event):
	# Only process if terminal is visible
	if not visible:
		return

	# Handle up/down arrow keys for command history
	# These need special handling since LineEdit doesn't use them
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_UP:
			_navigate_history(-1)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_DOWN:
			_navigate_history(1)
			get_viewport().set_input_as_handled()

func show_terminal():
	visible = true
	input_field.grab_focus()
	# Capture mouse for UI interaction
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Disable player input processing
	_set_player_input_enabled(false)

func hide_terminal():
	visible = false
	input_field.release_focus()
	# Return mouse to captured mode for gameplay
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Re-enable player input processing
	_set_player_input_enabled(true)

func _set_player_input_enabled(enabled: bool):
	"""Enable or disable player input processing"""
	# Get the local player from the world script
	if world_script and "players" in world_script:
		var my_peer_id = multiplayer.get_unique_id()
		if world_script.players.has(my_peer_id):
			var player = world_script.players[my_peer_id]
			if player and is_instance_valid(player):
				player.set_physics_process(enabled)

func toggle_terminal():
	if visible:
		hide_terminal()
	else:
		show_terminal()

func _on_input_submitted(text: String):
	if text.strip_edges().is_empty():
		return
	
	# Add to history
	command_history.append(text)
	history_index = command_history.size()
	
	# Echo command
	add_output("[color=yellow]> " + text + "[/color]")
	
	# Process command
	_process_command(text.strip_edges())
	
	# Clear input
	input_field.clear()

func _navigate_history(direction: int):
	if command_history.is_empty():
		return
	
	history_index = clamp(history_index + direction, 0, command_history.size())
	
	if history_index < command_history.size():
		input_field.text = command_history[history_index]
		input_field.caret_column = input_field.text.length()
	else:
		input_field.clear()

func _process_command(command: String):
	# Split command into parts
	var parts = command.split(" ", false)
	if parts.is_empty():
		return
	
	var cmd = parts[0].to_lower()
	
	match cmd:
		"set_world":
			_cmd_set_world(parts)
		"set_nightmare":
			_cmd_set_nightmare(parts)
		"respawn":
			_cmd_respawn()
		"fly":
			_cmd_fly()
		"fall":
			_cmd_fall()
		"/help", "help":
			_cmd_help()
		"clear":
			_cmd_clear()
		_:
			add_output("[color=red]Unknown command: " + cmd + "[/color]")
			add_output("Type /help for available commands")

func _cmd_set_world(parts: Array):
	if parts.size() < 2:
		add_output("[color=red]Usage: set_world <number>[/color]")
		add_output("Example: set_world 2")
		return
	
	var world_num = parts[1]
	
	# Check if it's a valid number
	if not world_num.is_valid_int():
		add_output("[color=red]Error: '" + world_num + "' is not a valid number[/color]")
		return
	
	var world_name = "world" + world_num
	var nightmare_name = "nightmare" + world_num
	
	# Check if world exists
	if world_script and "worlds" in world_script and "nightmares" in world_script:
		var worlds = world_script.worlds
		var nightmares = world_script.nightmares
		
		if world_name in worlds:
			# Teleport to the world
			add_output("[color=green]Teleporting to " + world_name + "...[/color]")
			var spawn_pos = world_script.find_safe_spawn_position(world_name)
			world_script.teleport_to_world(world_name, spawn_pos)
		elif nightmare_name in nightmares:
			# Teleport to the nightmare
			add_output("[color=green]Teleporting to " + nightmare_name + "...[/color]")
			var spawn_pos = world_script.find_safe_spawn_position(nightmare_name)
			world_script.teleport_to_world(nightmare_name, spawn_pos)
		else:
			add_output("[color=red]Error: World does not exist[/color]")
	else:
		add_output("[color=red]Error: Could not access world data[/color]")

func _cmd_set_nightmare(parts: Array):
	if parts.size() < 2:
		add_output("[color=red]Usage: set_nightmare <number>[/color]")
		add_output("Example: set_nightmare 1")
		return

	var nightmare_num = parts[1]

	# Check if it's a valid number
	if not nightmare_num.is_valid_int():
		add_output("[color=red]Error: '" + nightmare_num + "' is not a valid number[/color]")
		return

	var nightmare_name = "nightmare" + nightmare_num

	# Check if nightmare exists
	if world_script and "nightmares" in world_script:
		var nightmares = world_script.nightmares

		if nightmare_name in nightmares:
			# Set nightmare to 100%
			if "nightmare_value" in world_script:
				world_script.nightmare_value = 100.0
				if "nightmare_bar" in world_script:
					world_script.nightmare_bar.value = 100.0

				# Sync to clients in multiplayer
				if "is_multiplayer" in world_script and world_script.is_multiplayer:
					if multiplayer.is_server():
						if world_script.has_method("sync_nightmare_value"):
							world_script.sync_nightmare_value.rpc(100.0)

			# Teleport to the nightmare
			add_output("[color=green]Setting nightmare to 100% and teleporting to " + nightmare_name + "...[/color]")
			var spawn_pos = world_script.find_safe_spawn_position(nightmare_name)
			world_script.teleport_to_world(nightmare_name, spawn_pos)
		else:
			add_output("[color=red]Error: Nightmare does not exist[/color]")
	else:
		add_output("[color=red]Error: Could not access nightmare data[/color]")

func _cmd_respawn():
	"""Respawn player at a player spawn point"""
	if not world_script:
		add_output("[color=red]Error: Could not access world script[/color]")
		return

	# Get current world name
	var current_world = world_script.current_world_name if "current_world_name" in world_script else ""
	if current_world.is_empty():
		add_output("[color=red]Error: Could not determine current world[/color]")
		return

	# Get player spawn points in current world
	var spawn_points = world_script.get_player_spawn_points(current_world)

	var spawn_pos: Vector3

	if spawn_points.size() == 0:
		# No spawn points - use fallback position
		add_output("[color=yellow]No spawn points found, using fallback position[/color]")
		spawn_pos = Vector3(0, 10, 0)
	elif spawn_points.size() == 1:
		# Only one spawn point - teleport to it
		add_output("[color=green]Teleporting to the only spawn point[/color]")
		spawn_pos = spawn_points[0].global_position
	else:
		# Multiple spawn points - pick a random one
		var random_index = randi() % spawn_points.size()
		add_output("[color=green]Teleporting to spawn point " + str(random_index + 1) + " of " + str(spawn_points.size()) + "[/color]")
		spawn_pos = spawn_points[random_index].global_position

	# Get local player and teleport them
	if "players" in world_script:
		var my_peer_id = multiplayer.get_unique_id()
		if world_script.players.has(my_peer_id):
			var player = world_script.players[my_peer_id]
			if player and is_instance_valid(player):
				player.global_position = spawn_pos
				# Reset velocity to prevent any residual movement
				if player is CharacterBody3D:
					player.velocity = Vector3.ZERO
				add_output("[color=green]Respawned at: " + str(spawn_pos) + "[/color]")
			else:
				add_output("[color=red]Error: Player node is invalid[/color]")
		else:
			add_output("[color=red]Error: Could not find local player[/color]")
	else:
		add_output("[color=red]Error: Could not access players data[/color]")

func _cmd_fly():
	"""Enable flying mode for the player"""
	if not world_script:
		add_output("[color=red]Error: Could not access world script[/color]")
		return

	# Get local player and enable flying
	if "players" in world_script:
		var my_peer_id = multiplayer.get_unique_id()
		if world_script.players.has(my_peer_id):
			var player = world_script.players[my_peer_id]
			if player and is_instance_valid(player):
				if player.has_method("enable_flying"):
					player.enable_flying()
					add_output("[color=green]Flying mode enabled![/color]")
					add_output("[color=yellow]W=forward, Space=up, S=down, Shift=down+fast[/color]")
				else:
					add_output("[color=red]Error: Player does not support flying[/color]")
			else:
				add_output("[color=red]Error: Player node is invalid[/color]")
		else:
			add_output("[color=red]Error: Could not find local player[/color]")
	else:
		add_output("[color=red]Error: Could not access players data[/color]")

func _cmd_fall():
	"""Disable flying mode for the player"""
	if not world_script:
		add_output("[color=red]Error: Could not access world script[/color]")
		return

	# Get local player and disable flying
	if "players" in world_script:
		var my_peer_id = multiplayer.get_unique_id()
		if world_script.players.has(my_peer_id):
			var player = world_script.players[my_peer_id]
			if player and is_instance_valid(player):
				if player.has_method("disable_flying"):
					player.disable_flying()
					add_output("[color=green]Flying mode disabled - back to normal movement[/color]")
				else:
					add_output("[color=red]Error: Player does not support flying[/color]")
			else:
				add_output("[color=red]Error: Player node is invalid[/color]")
		else:
			add_output("[color=red]Error: Could not find local player[/color]")
	else:
		add_output("[color=red]Error: Could not access players data[/color]")

func _cmd_help():
	add_output("[color=cyan]Available Commands:[/color]")
	add_output("  set_world <number> - Teleport to world")
	add_output("    Example: set_world 2")
	add_output("  set_nightmare <number> - Set nightmare to 100% and teleport")
	add_output("    Example: set_nightmare 1")
	add_output("  respawn - Respawn at a player spawn point")
	add_output("  fly - Enable flying (W=forward, Space=up, S/Shift=down+fast)")
	add_output("  fall - Disable flying mode")
	add_output("  clear - Clear terminal output")
	add_output("  /help - Show this help message")

func _cmd_clear():
	output_lines.clear()
	output_label.clear()

func add_output(text: String):
	output_lines.append(text)
	
	# Keep only last MAX_OUTPUT_LINES
	if output_lines.size() > MAX_OUTPUT_LINES:
		output_lines.remove_at(0)
	
	# Update display
	output_label.clear()
	for line in output_lines:
		output_label.append_text(line + "\n")
