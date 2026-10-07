extends VBoxContainer
## Bare-bones UI for the examples: a status line over a column of buttons and notes.

var status := Label.new()
var _items := VBoxContainer.new()


func _init() -> void:
	add_child(status)
	add_child(_items)


func say(text: String) -> void:
	status.text = text


func clear() -> void:
	for child in _items.get_children():
		_items.remove_child(child)
		child.queue_free()


func button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	_items.add_child(b)
	return b


func note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	_items.add_child(label)
	return label


## Puts the menu and [param game] in a column on [param parent].
func lay_out(parent: Control, game: Control) -> void:
	var column := VBoxContainer.new()
	column.position = Vector2(20, 20)
	column.add_theme_constant_override("separation", 12)
	column.add_child(self)
	column.add_child(game)
	parent.add_child(column)
