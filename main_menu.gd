extends Control

# UI References
@onready var start_button = $VBoxContainer/SinglePlayerButton
@onready var host_button = $VBoxContainer/HostGameButton
@onready var join_button = $VBoxContainer/JoinGameButton
@onready var start_multiplayer_button = $VBoxContainer/StartMultiplayerButton
@onready var copy_button = $VBoxContainer/CopyLobbyIDButton
@onready var lobby_id_label = $VBoxContainer/LobbyIDLabel
@onready var players_label = $VBoxContainer/PlayersLabel
@onready var lobby_input = $VBoxContainer/LobbyInput
@onready var status_label = $VBoxContainer/StatusLabel

var world_scene: PackedScene = load("res://world.tscn")
var lobby_id: int = 0
var is_host: bool = false
var lobby_members: Array = []
var peer: SteamMultiplayerPeer = null

# Short lobby code system
var short_lobby_code: String = ""

func _process(_delta: float) -> void:
	# Process Steam callbacks every frame
	Steam.run_callbacks()

func _ready() -> void:
	# Initialize Steam
	var initialize_response: Dictionary = Steam.steamInitEx()
	print("Steam Init Response: ", initialize_response)

	if initialize_response['status'] > 0:
		print("ERROR: Failed to initialize Steam!")
		status_label.text = "ERROR: Steam not running!"
		host_button.disabled = true
		join_button.disabled = true
	else:
		print("SUCCESS: Steam initialized!")
		var steam_name = Steam.getPersonaName()
		print("Your Steam Name: ", steam_name)
		status_label.text = "Welcome, " + steam_name + "!"

		# CRITICAL FIX: Initialize Steam Relay Network for P2P connections
		# This is REQUIRED for SteamMultiplayerPeer to work properly!
		print("Initializing Steam Relay Network for P2P...")
		Steam.initRelayNetworkAccess()
		print("Steam Relay Network access initialized")

		# Connect Steam signals
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_match_list.connect(_on_lobby_match_list)
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.lobby_chat_update.connect(_on_lobby_chat_update)
		Steam.lobby_data_update.connect(_on_lobby_data_update)
		# Note: lobby_join_requested might be named differently in some versions
		# We'll add Steam overlay invite support later

		# Connect multiplayer signals
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)

	# Hide lobby info initially (but keep input visible for joining)
	lobby_id_label.hide()
	# lobby_input stays visible so people can enter a lobby ID to join
	start_multiplayer_button.hide()
	copy_button.hide()
	players_label.hide()

# Single player - just start the game
func _on_single_player_pressed() -> void:
	start_game()

# Host a multiplayer game
func _on_host_game_pressed() -> void:
	status_label.text = "Creating lobby..."
	print("Creating Steam lobby...")

	# Create a lobby (2 players max, public so anyone can search and join with code)
	# IMPORTANT: Must use FRIENDS_ONLY or PUBLIC for requestLobbyList() to find it!
	# INVISIBLE lobbies cannot be found via lobby search!
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, 2)

# Join a multiplayer game
func _on_join_game_pressed() -> void:
	var input_text = lobby_input.text.strip_edges().to_upper()

	if input_text == "":
		status_label.text = "Please enter a Lobby Code!"
		return

	status_label.text = "Searching for lobby..."
	print("Searching for lobby with code: ", input_text)

	# CRITICAL: Set distance filter to WORLDWIDE so we can find lobbies across different regions!
	# Without this, Steam defaults to LOBBY_DISTANCE_FILTER_DEFAULT which only searches nearby regions
	# This is why you can't find your friend's lobby if they're in a different geographic region!
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)

	# Search for lobbies with matching short code
	# We'll use Steam's lobby list to find the matching lobby
	Steam.addRequestLobbyListStringFilter("short_code", input_text, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.requestLobbyList()

# Called when lobby is created
func _on_lobby_created(connect_status: int, created_lobby_id: int) -> void:
	if connect_status == 1:  # Success
		lobby_id = created_lobby_id
		is_host = true
		print("Lobby created! ID: ", lobby_id)

		# DON'T create multiplayer peer yet - wait until we start the game
		# This way the client will be in the lobby when we create the peer

		# Generate a short, readable lobby code (6 characters)
		short_lobby_code = _generate_short_code()

		# Store the mapping in Steam lobby data so others can look it up
		Steam.setLobbyData(lobby_id, "short_code", short_lobby_code)

		lobby_id_label.text = "Lobby Code: " + short_lobby_code
		lobby_id_label.show()
		copy_button.show()
		status_label.text = "Lobby created! Share the code with your friend!"

		# Hide main menu buttons, show start button and players
		start_button.hide()
		host_button.hide()
		join_button.hide()
		lobby_input.hide()
		start_multiplayer_button.show()
		players_label.show()

		# Update player list
		update_lobby_members()
	else:
		status_label.text = "Failed to create lobby!"
		print("Failed to create lobby. Status: ", connect_status)

# Called when we join a lobby
func _on_lobby_joined(lobby_id_joined: int, _permissions: int, _locked: bool, response: int) -> void:
	if response == 1:  # Success
		# Don't auto-start if we're the host joining our own lobby
		if lobby_id_joined == lobby_id and is_host:
			print("Host joined their own lobby: ", lobby_id)
			return

		# We're a client joining someone else's lobby
		lobby_id = lobby_id_joined
		is_host = false
		print("Successfully joined lobby: ", lobby_id)

		# DON'T create multiplayer peer yet - wait until host starts the game
		# We'll create it in the RPC handler

		status_label.text = "Joined lobby! Waiting for host to start..."

		# Hide buttons, show players
		start_button.hide()
		host_button.hide()
		join_button.hide()
		lobby_input.hide()
		players_label.show()

		# Update player list
		update_lobby_members()
	else:
		status_label.text = "Failed to join lobby!"
		print("Failed to join lobby. Response: ", response)

# Copy lobby code to clipboard
func _on_copy_lobby_id_pressed() -> void:
	DisplayServer.clipboard_set(short_lobby_code)
	status_label.text = "Lobby code copied to clipboard!"
	print("Copied lobby code to clipboard: ", short_lobby_code)

# Called when lobby members change (someone joins/leaves)
func _on_lobby_chat_update(_lobby_id: int, _changed_id: int, _making_change_id: int, _chat_state: int) -> void:
	print("Lobby members changed!")
	update_lobby_members()

# Update the list of players in the lobby
func update_lobby_members() -> void:
	var num_members = Steam.getNumLobbyMembers(lobby_id)
	print("Lobby has ", num_members, " members")

	lobby_members.clear()
	var player_names = []

	for i in range(num_members):
		var member_id = Steam.getLobbyMemberByIndex(lobby_id, i)
		var member_name = Steam.getFriendPersonaName(member_id)
		lobby_members.append(member_id)
		player_names.append(member_name)
		print("  - ", member_name, " (", member_id, ")")

	# Update UI
	players_label.text = "Players (" + str(num_members) + "/2):\n" + "\n".join(player_names)

# Host clicks "Start Game" button
func _on_start_multiplayer_pressed() -> void:
	if is_host:
		print("=== HOST STARTING GAME ===")
		print("My Steam ID: ", Steam.getSteamID())
		print("Lobby ID: ", lobby_id)
		status_label.text = "Starting game..."

		# NOW create the multiplayer peer as host
		print("Creating host multiplayer peer...")
		peer = SteamMultiplayerPeer.new()

		# CRITICAL: Use virtual port 0 (clients must use the same port)
		var create_result = peer.create_host(0)
		print("create_host() result: ", create_result)

		if create_result != OK:
			print("ERROR: create_host() failed with code: ", create_result)
			status_label.text = "Failed to create host!"
			return

		multiplayer.multiplayer_peer = peer
		print("✓ Host peer created successfully")

		# Set lobby data to signal clients to start
		var my_steam_id = Steam.getSteamID()
		print("Setting lobby data - game_started with host Steam ID: ", my_steam_id)
		Steam.setLobbyData(lobby_id, "game_started", str(my_steam_id))

		# Wait longer for clients to fully connect and establish peer connection
		await get_tree().create_timer(3.0).timeout

		print("Host starting world with connected peers: ", multiplayer.get_peers())

		# Start the game for the host
		start_game()
	else:
		print("Only the host can start the game!")

# Called when lobby data changes (used to signal game start)
func _on_lobby_data_update(_lobby_id: int, _member_id: int, _key: int) -> void:
	print("Lobby data updated!")

	# Check if the game has started
	var game_started_data = Steam.getLobbyData(lobby_id, "game_started")
	print("game_started data: ", game_started_data)

	if game_started_data != "" and not is_host:
		var host_steam_id = int(game_started_data)
		print("=== CLIENT CONNECTION DEBUG ===")
		print("Host Steam ID from lobby: ", host_steam_id)
		print("My Steam ID: ", Steam.getSteamID())
		print("Lobby ID: ", lobby_id)

		# CRITICAL VALIDATION: Make sure we're not connecting to ourselves
		if host_steam_id == Steam.getSteamID():
			print("ERROR: Trying to connect to ourselves!")
			status_label.text = "ERROR: Invalid host ID!"
			return

		# CRITICAL VALIDATION: Make sure this isn't the lobby ID
		if host_steam_id == lobby_id:
			print("ERROR: host_steam_id is the lobby ID, not the host's Steam ID!")
			print("This is a common bug - make sure you're passing the HOST'S Steam ID, not the lobby ID!")
			status_label.text = "ERROR: Wrong ID type!"
			return

		status_label.text = "Connecting to host..."

		# Create the multiplayer peer as client
		print("Creating client multiplayer peer...")
		peer = SteamMultiplayerPeer.new()
		var join_result = peer.create_client(host_steam_id, 0)
		print("Client peer created with result: ", join_result)

		if join_result != OK:
			print("ERROR: create_client() failed with code: ", join_result)
			status_label.text = "Failed to create peer!"
			return

		# DON'T set multiplayer_peer yet - wait for connection first
		# multiplayer.multiplayer_peer = peer

		# Poll the peer connection status
		print("Polling peer connection status...")
		var connection_timeout = 10.0
		var elapsed = 0.0
		var connected = false

		while elapsed < connection_timeout:
			peer.poll()  # Update peer state
			var status = peer.get_connection_status()
			print("Peer status: ", status, " (0=DISCONNECTED, 1=CONNECTING, 2=CONNECTED)")

			if status == MultiplayerPeer.CONNECTION_CONNECTED:
				connected = true
				print("✓ Peer connected!")
				break
			elif status == MultiplayerPeer.CONNECTION_DISCONNECTED and elapsed > 1.0:
				print("✗ Connection failed!")
				break

			await get_tree().create_timer(0.1).timeout
			elapsed += 0.1

			# Update status every second
			if int(elapsed) != int(elapsed - 0.1):
				status_label.text = "Connecting... (" + str(int(connection_timeout - elapsed)) + "s)"

		if connected:
			print("Setting multiplayer peer...")
			multiplayer.multiplayer_peer = peer

			# Wait for peer list to update
			await get_tree().create_timer(0.5).timeout

			print("Client connected! Peers: ", multiplayer.get_peers())
			status_label.text = "Connected! Starting game..."

			start_game()
		else:
			print("ERROR: Connection timeout or failed!")
			status_label.text = "Connection failed"

# Multiplayer connection callbacks
func _on_peer_connected(id: int) -> void:
	print("Peer connected: ", id)
	status_label.text = "Player connected!"

func _on_peer_disconnected(id: int) -> void:
	print("Peer disconnected: ", id)
	status_label.text = "Player disconnected!"

func _on_connected_to_server() -> void:
	print("Successfully connected to server (host)!")
	status_label.text = "Connected to host!"

func _on_connection_failed() -> void:
	print("Failed to connect to server!")
	status_label.text = "Connection failed!"

# Called when lobby search completes
func _on_lobby_match_list(lobbies: Array) -> void:
	print("Found ", lobbies.size(), " lobbies matching search")

	if lobbies.size() == 0:
		status_label.text = "Lobby code not found!"
		print("ERROR: No lobbies found with code: ", lobby_input.text.strip_edges().to_upper())
		print("Make sure:")
		print("  1. The host has created the lobby")
		print("  2. You entered the correct code")
		print("  3. You are Steam friends (if using FRIENDS_ONLY lobby type)")
		return

	# Join the first matching lobby
	var lobby_to_join = lobbies[0]
	print("Joining lobby: ", lobby_to_join)

	# Debug: Print lobby data
	var lobby_code = Steam.getLobbyData(lobby_to_join, "short_code")
	print("Lobby short_code: ", lobby_code)

	status_label.text = "Joining lobby..."
	Steam.joinLobby(lobby_to_join)

# Generate a short, readable lobby code (6 characters: letters and numbers)
func _generate_short_code() -> String:
	const CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # Removed confusing chars like I, O, 0, 1
	var code = ""
	for i in range(6):
		code += CHARS[randi() % CHARS.length()]
	return code

# Start the actual game
func start_game() -> void:
	if world_scene:
		var world = world_scene.instantiate()
		get_tree().root.add_child(world)
		queue_free()
		print("World started!")
	else:
		print("World scene not assigned!")

# Open settings menu
func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://settings_menu.tscn")
