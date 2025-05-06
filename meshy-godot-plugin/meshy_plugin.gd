@tool
extends EditorPlugin

const MainPanel = preload("res://addons/meshy-godot-plugin/main_panel.tscn")

var main_panel_instance: CenterContainer


func _enter_tree() -> void:
	main_panel_instance = MainPanel.instantiate()
	main_panel_instance.editor_interface = get_editor_interface()
	# Add the main panel to the editor's main viewport.
	get_editor_interface().get_editor_main_screen().add_child(main_panel_instance)
	# Hide the main panel. Very much required.
	_make_visible(false)


func _exit_tree() -> void:
	if main_panel_instance:
		main_panel_instance.queue_free()


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if main_panel_instance:
		main_panel_instance.visible = visible


func _get_plugin_name() -> String:
	return "Meshy"


func _get_plugin_icon() -> Texture2D:
	var icon = preload("res://addons/meshy-godot-plugin/Meshy_Icon_36.png")
	if icon:
		return icon
	return get_editor_interface().get_base_control().get_theme_icon("Node", "EditorIcons")
