extends Node3D
## Background sound: a low room drone, and now and then a distant sound somewhere on the player's floor
## (creaks, drips, pipes knocking, wind, rarely a door slamming far away). Scary, but not too often.

var game
var drone: AudioStreamPlayer
var timer := 8.0
var rng := RandomNumberGenerator.new()
const EVENTS := [["creak_far_1", 3.0, -8.0], ["creak_far_2", 3.0, -9.0], ["drip", 3.0, -10.0],
	["pipes_knock", 2.0, -9.0], ["wind_gust", 2.0, -12.0], ["door_slam_far", 0.8, -6.0], ["whisper_far", 0.3, -18.0]]


func setup(g) -> void:
	game = g
	rng.seed = 1977
	drone = AudioStreamPlayer.new()
	drone.stream = g.sfx("ambience_loop", true)
	drone.volume_db = -15.0
	add_child(drone)
	drone.play()


func _process(dt: float) -> void:
	if game.player == null:
		return
	timer -= dt
	if timer > 0.0:
		return
	timer = rng.randf_range(14.0, 40.0)
	var total := 0.0
	for e in EVENTS:
		total += e[1]
	var x := rng.randf() * total
	var pick: Array = EVENTS[0]
	for e in EVENTS:
		x -= e[1]
		if x <= 0.0:
			pick = e
			break
	var a := rng.randf() * TAU
	var d := rng.randf_range(9.0, 24.0)
	var p: Vector3 = game.player.global_position + Vector3(cos(a) * d, 1.6, sin(a) * d)
	game.play_at(pick[0], p, pick[2] + rng.randf_range(-2.0, 2.0), rng.randf_range(0.85, 1.1), 40.0)
	if pick[0] == "door_slam_far":
		game.critters.scare(p, 10.0)
