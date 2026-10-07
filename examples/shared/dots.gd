extends Control
## The game every example plays: each player steers a dot with the arrow keys, around any
## walls the stage has. It knows nothing about the network.
##
## It runs in lockstep, so every device must step it identically from the same inputs:
## integers only, no randomness, nothing that depends on frame times. [method checksum]
## lets the devices check that they agree.

const SPEED := 4
const SIZE := Vector2i(600, 300)
const COLOURS := [Color.TOMATO, Color.DEEP_SKY_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]
const KEYS := ["ui_left", "ui_right", "ui_up", "ui_down"]

var positions: Array[Vector2i] = []
var walls: Array[Rect2i] = []
var speed := SPEED


func _init() -> void:
	custom_minimum_size = Vector2(SIZE)


func reset(players: int, stage_walls: Array[Rect2i] = [], dot_speed := SPEED) -> void:
	walls = stage_walls
	speed = dot_speed
	positions.clear()
	for slot in players:
		positions.append(Vector2i(40 + slot * 60, SIZE.y / 2))
	queue_redraw()


## This device's input for a tick: one byte, a bit per arrow key.
func sample_input(_tick: int) -> PackedByteArray:
	var bits := 0
	for i in KEYS.size():
		if Input.is_action_pressed(KEYS[i]):
			bits |= 1 << i
	return PackedByteArray([bits])


## Steps one tick with every player's input, in slot order.
func step(_tick: int, inputs: Array[PackedByteArray]) -> void:
	for slot in inputs.size():
		var bits := inputs[slot][0]
		var move := Vector2i(((bits >> 1) & 1) - (bits & 1), ((bits >> 3) & 1) - ((bits >> 2) & 1))
		var next := (positions[slot] + move * speed).clamp(Vector2i.ZERO, SIZE)
		if not walls.any(func(wall): return wall.has_point(next)):
			positions[slot] = next
	queue_redraw()


## A hash of the state (FNV-1a over the positions).
func checksum() -> int:
	var h := 2166136261
	for p in positions:
		h = ((h ^ p.x) * 16777619) & 0xFFFFFFFF
		h = ((h ^ p.y) * 16777619) & 0xFFFFFFFF
	return h


func _draw() -> void:
	if positions.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, SIZE), Color(1, 1, 1, 0.08))
	for wall in walls:
		draw_rect(Rect2(wall), Color(1, 1, 1, 0.3))
	for slot in positions.size():
		draw_circle(Vector2(positions[slot]), 10, COLOURS[slot % COLOURS.size()])
