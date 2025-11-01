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
		var steam_id = Steam.getSteamID()
		print("Your Steam Name: ", steam_name)
		print("Your Steam ID: ", steam_id)
		status_label.text = "Welcome, " + steam_name + "!"

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

	# Create a lobby (2 players max)
	# Changed to PUBLIC so anyone can join with the ID (not just Steam friends)
	# If you want friends only, use Steam.LOBBY_TYPE_FRIENDS_ONLY
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, 2)

# Join a multiplayer game
func _on_join_game_pressed() -> void:
	var input_text = lobby_input.text.strip_edges()

	if input_text == "":
		status_label.text = "Please enter a Lobby ID!"
		return

	# Convert the input to a lobby ID - Steam IDs are 64-bit
	# Use int() for smaller numbers, but for Steam IDs we need to handle larger numbers
	var lobby_to_join = 0
	if input_text.is_valid_int():
		lobby_to_join = int(input_text)
	else:
		status_label.text = "Invalid Lobby ID format!"
		return

	if lobby_to_join == 0:
		status_label.text = "Invalid Lobby ID!"
		return

	status_label.text = "Joining lobby..."
	print("Attempting to join lobby: ", lobby_to_join, " (type: ", typeof(lobby_to_join), ")")
	Steam.joinLobby(lobby_to_join)

# Called when lobby is created
func _on_lobby_created(connect_status: int, created_lobby_id: int) -> void:
	if connect_status == 1:  # Success
		lobby_id = created_lobby_id
		is_host = true
		print("Lobby created! ID: ", lobby_id)

		# DON'T create multiplayer peer yet - wait until we start the game
		# This way the client will be in the lobby when we create the peer

		lobby_id_label.text = "Lobby ID: " + str(lobby_id)
		lobby_id_label.show()
		copy_button.show()
		status_label.text = "Lobby created! Share the ID with your friend!"

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
	print("_on_lobby_joined called - Lobby: ", lobby_id_joined, " Response: ", response, " Is Host: ", is_host)

	# Response codes: 1 = success, 2 = doesn't exist, 3 = not allowed, 4 = full, etc
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
		var error_msg = "Unknown error"
		match response:
			2: error_msg = "Lobby doesn't exist"
			3: error_msg = "Not allowed to join"
			4: error_msg = "Lobby is full"
			5: error_msg = "Error in response"
			6: error_msg = "Banned from lobby"
			7: error_msg = "Limited user"
			8: error_msg = "Clan disabled"
			9: error_msg = "Community ban"
			10: error_msg = "Member blocked you"

		status_label.text = "Failed to join: " + error_msg
		print("Failed to join lobby. Response code: ", response, " - ", error_msg)

# Copy lobby ID to clipboard
func _on_copy_lobby_id_pressed() -> void:
	DisplayServer.clipboard_set(str(lobby_id))
	status_label.text = "Lobby ID copied to clipboard!"
	print("Copied lobby ID to clipboard: ", lobby_id)

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
		print("Host starting the game!")
		status_label.text = "Starting game..."

		# NOW create the multiplayer peer as host
		print("Creating host multiplayer peer...")
		peer = SteamMultiplayerPeer.new()
		var create_result = peer.create_host(0)
		print("Host peer created with result: ", create_result)

		if create_result != OK:
			print("ERROR: Failed to create host peer! Error code: ", create_result)
			status_label.text = "Failed to create host!"
			return

		multiplayer.multiplayer_peer = peer
		print("Host connection status: ", peer.get_connection_status())

		# Set lobby data to signal clients to start
		var my_steam_id = Steam.getSteamID()
		print("Setting lobby data - game_started with host Steam ID: ", my_steam_id)
		Steam.setLobbyData(lobby_id, "game_started", str(my_steam_id))

		# Wait for clients to connect to the multiplayer peer
		status_label.text = "Waiting for players to connect..."

		# Give time for clients to establish connection
		var wait_attempts = 0
		var expected_clients = Steam.getNumLobbyMembers(lobby_id) - 1  # -1 for host
		var max_wait = 20  # 10 seconds total

		while multiplayer.get_peers().size() < expected_clients and wait_attempts < max_wait:
			await get_tree().create_timer(0.5).timeout
			print("Host waiting for clients... (", multiplayer.get_peers().size(), "/", expected_clients, ") | Status: ", peer.get_connection_status(), " | Attempt: ", wait_attempts + 1)
			wait_attempts += 1

		print("Host starting world with connected peers: ", multiplayer.get_peers())

		if multiplayer.get_peers().size() == 0:
			print("WARNING: No clients connected to host!")

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
		print("Client: Game started! Connecting to host Steam ID: ", host_steam_id)
		status_label.text = "Connecting to host..."

		# Create the multiplayer peer as client
		print("Creating client multiplayer peer...")
		peer = SteamMultiplayerPeer.new()
		var join_result = peer.create_client(host_steam_id, 0)
		print("Client peer created with result: ", join_result)

		if join_result != OK:
			print("ERROR: Failed to create client peer! Error code: ", join_result)
			status_label.text = "Failed to create connection!"
			return

		multiplayer.multiplayer_peer = peer

		# Wait for connection to fully establish
		status_label.text = "Connecting to host..."

		# Keep waiting until we're connected to at least one peer
		# Steam.run_callbacks() is already being called in _process()
		var wait_attempts = 0
		var max_attempts = 20  # 10 seconds total
		var connected = false

		while wait_attempts < max_attempts:
			await get_tree().create_timer(0.5).timeout

			# Check connection status
			var connection_status = peer.get_connection_status()
			var peer_count = multiplayer.get_peers().size()
			print("Client connection status: ", connection_status, " | Peers: ", multiplayer.get_peers())

			# Connection is established when status is CONNECTED or we can see peers
			if connection_status == MultiplayerPeer.CONNECTION_CONNECTED or peer_count > 0:
				connected = true
				print("Client connection established!")
				break

			wait_attempts += 1

		if connected:
			print("Client starting world, connected to peers: ", multiplayer.get_peers())
			status_label.text = "Starting game..."
			await get_tree().create_timer(0.5).timeout  # Brief delay to ensure everything is ready
			start_game()
		else:
			print("ERROR: Client failed to connect to host!")
			print("Final connection status: ", peer.get_connection_status())
			status_label.text = "Failed to connect to host!"

# Multiplayer connection callbacks
func _on_peer_connected(id: int) -> void:
	print("Peer connected: ", id)
	status_label.text = "Player connected!"

	# If we're the client and we just connected to the server, we might need to start
	if not is_host and not multiplayer.is_server():
		print("Client detected peer connection (server connected)!")

func _on_peer_disconnected(id: int) -> void:
	print("Peer disconnected: ", id)
	status_label.text = "Player disconnected!"

func _on_connected_to_server() -> void:
	print("Successfully connected to server (host)!")
	status_label.text = "Connected to host!"

func _on_connection_failed() -> void:
	print("Failed to connect to server!")
	status_label.text = "Connection failed!"

# Placeholder for lobby match list (not used yet, but good to have)
func _on_lobby_match_list(lobbies: Array) -> void:
	print("Found lobbies: ", lobbies)

# Start the actual game
func start_game() -> void:
	if world_scene:
		var world = world_scene.instantiate()
		get_tree().root.add_child(world)
		queue_free()
		print("World started!")
	else:
		print("World scene not assigned!")
