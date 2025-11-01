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
		print("Your Steam Name: ", steam_name)
		status_label.text = "Welcome, " + steam_name + "!"

		# Connect Steam signals
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_match_list.connect(_on_lobby_match_list)
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.lobby_chat_update.connect(_on_lobby_chat_update)
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

	# Create a lobby (2 players max, private)
	Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, 2)

# Join a multiplayer game
func _on_join_game_pressed() -> void:
	var input_text = lobby_input.text.strip_edges()

	if input_text == "":
		status_label.text = "Please enter a Lobby ID!"
		return

	# Convert the input to a lobby ID
	var lobby_to_join = int(input_text)

	if lobby_to_join == 0:
		status_label.text = "Invalid Lobby ID!"
		return

	status_label.text = "Joining lobby..."
	print("Attempting to join lobby: ", lobby_to_join)
	Steam.joinLobby(lobby_to_join)

# Called when lobby is created
func _on_lobby_created(connect_status: int, created_lobby_id: int) -> void:
	if connect_status == 1:  # Success
		lobby_id = created_lobby_id
		is_host = true
		print("Lobby created! ID: ", lobby_id)

		# Create the multiplayer peer as host
		peer = SteamMultiplayerPeer.new()
		var create_result = peer.create_host(0)
		print("Host peer created with result: ", create_result)
		multiplayer.multiplayer_peer = peer

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
	if response == 1:  # Success
		# Don't auto-start if we're the host joining our own lobby
		if lobby_id_joined == lobby_id and is_host:
			print("Host joined their own lobby: ", lobby_id)
			return

		# We're a client joining someone else's lobby
		lobby_id = lobby_id_joined
		is_host = false
		print("Successfully joined lobby: ", lobby_id)

		# Get the host's Steam ID (first member of the lobby)
		var host_steam_id = Steam.getLobbyOwner(lobby_id)
		print("Connecting to host Steam ID: ", host_steam_id)

		# Create the multiplayer peer as client
		peer = SteamMultiplayerPeer.new()
		var join_result = peer.create_client(host_steam_id, 0)
		print("Client peer created with result: ", join_result)
		multiplayer.multiplayer_peer = peer

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
		print("Multiplayer peer status: ", multiplayer.multiplayer_peer)
		print("Connected peers: ", multiplayer.get_peers())
		status_label.text = "Starting game..."
		# Tell all clients to start the game
		print("Sending RPC to start game for all clients...")
		start_game_for_all.rpc()
		# Start the game for the host too
		start_game()
	else:
		print("Only the host can start the game!")

# RPC called by host to tell clients to start the game
@rpc("authority", "call_remote", "reliable")
func start_game_for_all() -> void:
	print("Received start game command from host!")
	status_label.text = "Host started the game!"
	await get_tree().create_timer(0.5).timeout
	start_game()

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
