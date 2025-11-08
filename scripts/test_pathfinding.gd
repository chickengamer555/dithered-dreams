extends Node3D

## 🔥 TEST SCENE FOR LAZY THETA* + ORCA PATHFINDING 🔥
## Monster handles all pathfinding internally!

@onready var monster: CharacterBody3D = $MonsterBase
@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Camera3D

var diagnostics_run = false
var frame_count = 0

func _ready():
	print("🔥🔥🔥 PATHFINDING TEST SCENE 🔥🔥🔥")
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	# Wait for physics to initialize
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Setup monster
	if monster:
		monster.use_navigation = false
		monster.target_player = player
		print("✅ Monster configured - Lazy Theta* + ORCA active!")
		print("   Position: ", monster.global_position)
		print("   Speed: ", monster.speed)
		print("   Target: ", player.global_position if player else "NULL")
	else:
		print("❌ ERROR: No MonsterBase found!")

	print("")
	print("✅ SYSTEM READY!")
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	print("🎯 Monster uses:")
	print("  ✓ Lazy Theta* - Any-angle pathfinding")
	print("  ✓ ORCA - Collision avoidance (other monsters only)")
	print("  ✓ Dynamic replanning - 5 updates/sec")
	print("  ✓ Real-time raycasting")
	print("")
	print("⏳ Waiting 3 seconds for pathfinding initialization...")

	# Wait for initialization
	await get_tree().create_timer(3.0).timeout

	print("")
	print("🔬 RUNNING DIAGNOSTICS...")
	run_diagnostics()

func _physics_process(_delta):
	frame_count += 1

	# Run diagnostics every 2 seconds
	if not diagnostics_run and frame_count % 120 == 0:
		print("")
		print("🔬 FRAME ", frame_count, " DIAGNOSTICS:")
		run_diagnostics()

func run_diagnostics():
	"""Run comprehensive diagnostics on pathfinding system"""
	if not monster:
		print("❌ Monster is null!")
		return

	print("")
	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	print("MONSTER STATUS:")
	print("  Position: ", monster.global_position)
	print("  Velocity: ", monster.velocity)
	print("  On Floor: ", monster.is_on_floor())
	print("  Has Target: ", monster.target_player != null)

	if monster.target_player:
		var dist = monster.global_position.distance_to(monster.target_player.global_position)
		print("  Distance to target: ", snappedf(dist, 0.01))

	print("")
	print("LAZY THETA* STATUS:")
	if not monster.lazy_theta_star:
		print("  ❌ lazy_theta_star is NULL!")
	else:
		var lts = monster.lazy_theta_star
		print("  Initialized: ", lts.is_initialized if "is_initialized" in lts else "UNKNOWN")
		print("  Space State: ", "VALID" if lts.space_state else "NULL")
		print("  Grid Size: ", lts.grid.size() if "grid" in lts else "UNKNOWN")
		print("  Cell Size: ", lts.cell_size if "cell_size" in lts else "UNKNOWN")
		print("  Agent Radius: ", lts.agent_radius if "agent_radius" in lts else "UNKNOWN")

		# Test path request
		if lts.is_initialized and monster.target_player:
			print("")
			print("  🧪 Testing path from ", monster.global_position, " to ", monster.target_player.global_position)
			var start_time = Time.get_ticks_usec()
			var test_path = lts.find_path(monster.global_position, monster.target_player.global_position)
			var end_time = Time.get_ticks_usec()
			var time_ms = (end_time - start_time) / 1000.0

			print("  Path Result: ", test_path.size(), " waypoints in ", snappedf(time_ms, 0.01), "ms")

			if test_path.size() == 0:
				print("  ❌ NO PATH FOUND!")

				# Debug grid cells
				var start_cell = lts._world_to_grid(monster.global_position)
				var end_cell = lts._world_to_grid(monster.target_player.global_position)

				print("  Start Cell: ", start_cell, " - Walkable: ", lts.grid.has(start_cell))
				print("  End Cell: ", end_cell, " - Walkable: ", lts.grid.has(end_cell))
			else:
				print("  ✅ PATH FOUND!")
				for i in range(min(5, test_path.size())):
					print("    Waypoint ", i, ": ", test_path[i])

	print("")
	print("ORCA STATUS:")
	if not monster.orca_avoidance:
		print("  ❌ orca_avoidance is NULL!")
	else:
		var orca = monster.orca_avoidance
		print("  Time Horizon: ", orca.time_horizon if "time_horizon" in orca else "UNKNOWN")
		print("  Agent Radius: ", orca.agent_radius if "agent_radius" in orca else "UNKNOWN")
		print("  Max Speed: ", orca.max_speed if "max_speed" in orca else "UNKNOWN")

	print("")
	print("PATHFINDING STATE:")
	if "current_path" in monster:
		print("  Current Path Size: ", monster.current_path.size())
		print("  Current Path Index: ", monster.current_path_index)
		print("  Path Update Timer: ", snappedf(monster.path_update_timer, 0.01) if "path_update_timer" in monster else "UNKNOWN")
	else:
		print("  ❌ No current_path property!")

	print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	print("")

	diagnostics_run = true
