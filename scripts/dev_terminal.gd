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
	if not visible:
		return
	
	# Handle up/down arrow keys for command history
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

func hide_terminal():
	visible = false
	input_field.release_focus()
	# Return mouse to captured mode for gameplay
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

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

func _cmd_help():
	add_output("[color=cyan]Available Commands:[/color]")
	add_output("  set_world <number> - Teleport to world")
	add_output("    Example: set_world 2")
	add_output("  set_nightmare <number> - Set nightmare to 100% and teleport")
	add_output("    Example: set_nightmare 1")
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
