@tool
extends CenterContainer

var bridge_running = false
var tcp_server: TCPServer
var peerTCP: StreamPeerTCP
var server_port = 5325
var editor_interface: EditorInterface

func _ready():
	tcp_server = TCPServer.new()
	_update_status_label()

func _process(_delta):
	if bridge_running and tcp_server and tcp_server.is_connection_available():
		peerTCP = tcp_server.take_connection()
	if peerTCP != null:
		_handle_peer_tcp()

func _update_status_label():
	var status_label = $VBoxContainer/StatusLabel
	if status_label:
		status_label.text = "Bridge: " + ("Running" if bridge_running else "Stopped")
	var bridge_button = $VBoxContainer/Bridge
	if bridge_button:
		bridge_button.text = "Stop Meshy Bridge" if bridge_running else "Run Meshy Bridge"

func _on_open_meshy_pressed() -> void:
	OS.shell_open("https://www.meshy.ai/")

func _on_run_bridge_pressed():
	bridge_running = !bridge_running
	if bridge_running:
		var error = tcp_server.listen(server_port)
		if error != OK:
			bridge_running = false
	else:
		tcp_server.stop()
	_update_status_label()

func _handle_peer_tcp():
	var status = peerTCP.get_status()
	if status == 3:
		peerTCP = null
	elif status == 2:
		var code = peerTCP.poll()
		var bytes := peerTCP.get_available_bytes()
		if bytes > 0:
			var data := peerTCP.get_data(bytes)
			if data[0] == 0:
				var request_str = _bytes_to_string(data[1])
				_handle_http_request(request_str)

func _bytes_to_string(bytes: PackedByteArray) -> String:
	return bytes.get_string_from_ascii()

func _handle_http_request(request_str: String):
	var request_lines = request_str.split("\n")
	if request_lines.is_empty():
		return
	var request_line = request_lines[0].split(" ")
	if request_line.size() < 2:
		return
	var method = request_line[0]
	var path = request_line[1]

	var response = {}
	
	if method == "GET" and (path == "/status" or path == "/ping"):
		response = {
			"status": "ok",
			"dcc": "godot",
			"version": Engine.get_version_info().string
		}
		_send_json_response(peerTCP, response, 200)
	elif  path == "/import":
		if method == "OPTIONS":
			_send_cors_headers(peerTCP)
		elif method == "POST":
			var body_start = request_str.find("\r\n\r\n") + 4
			if body_start > 0:
				var body = request_str.substr(body_start)
				var json = JSON.parse_string(body)
				_download_and_import_file(json)
				await get_tree().create_timer(2.0).timeout
				_send_json_response(peerTCP, {
					"status": "ok",
					"message": "File imported successfully"
				}, 200)
		else:
			response = {
				"status": "error",
				"message": "Invalid request format"
			}
			_send_json_response(peerTCP, response, 400)
	else:
		response = {
			"status": "path not found"
		}
		_send_json_response(peerTCP, response, 404)

func _send_cors_headers(client):
	var response = "HTTP/1.1 200 OK\r\n"
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
	response += "Access-Control-Allow-Headers: *\r\n"
	response += "Access-Control-Max-Age: 86400\r\n"
	response += "Content-Length: 0\r\n"
	response += "\r\n"
	client.put_data(response.to_utf8_buffer())

func _send_json_response(client, data, status_code = 200):
	var json = JSON.stringify(data)
	var response = "HTTP/1.1 " + str(status_code) + " OK\r\n"
	response += "Content-Type: application/json\r\n"
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
	response += "Access-Control-Allow-Headers: *\r\n"
	response += "Content-Length: " + str(json.length()) + "\r\n"
	response += "\r\n"
	response += json
	client.put_data(response.to_utf8_buffer())
	client.disconnect_from_host()

func _download_and_import_file(json_payload):
	var http = HTTPRequest.new()
	add_child(http)
	http.connect("request_completed", _on_download_completed.bind(json_payload))
	var error = http.request(json_payload.url)
	if error != OK:
		http.queue_free()

func _on_download_completed(result, response_code, headers, body, json_payload):
	if result != HTTPRequest.RESULT_SUCCESS:
		return
	if response_code != 200:
		return
	var res_dir = "res://imported_models"
	var dir = DirAccess.open("res://")
	if not dir.dir_exists(res_dir):
		dir.make_dir(res_dir)
	var file_name = "meshy_model_" + str(Time.get_unix_time_from_system()) + "." + json_payload.format
	var file_path = res_dir.path_join(file_name)
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_buffer(body)
		file.flush()
		file = null
		if FileAccess.file_exists(file_path):
			if editor_interface:
				var filesystem = editor_interface.get_resource_filesystem()
				filesystem.scan()
			_wait_for_file_recognition(file_path)

func _wait_for_file_recognition(file_path: String) -> void:
	if ResourceLoader.exists(file_path):
		_continue_import(file_path)
		return
	var timer = Timer.new()
	timer.wait_time = 0.2
	timer.one_shot = false
	add_child(timer)
	var retry_count = 0
	var max_retries = 10
	timer.timeout.connect(func():
		retry_count += 1
		if ResourceLoader.exists(file_path):
			timer.queue_free()
			_continue_import(file_path)
			return
		if retry_count >= max_retries:
			timer.queue_free()
	)
	timer.start()

func _continue_import(file_path: String) -> void:
	var name = file_path.get_file().get_basename()
	var json_payload = {
		"name": name
	}
	_import_model(file_path, json_payload)

func _import_model(file_path, json_payload):
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return
	var magic_bytes = file.get_buffer(4)
	file.close()
	var detected_format = ""
	if magic_bytes.size() >= 4:
		if magic_bytes[0] == 0x67 and magic_bytes[1] == 0x6C and magic_bytes[2] == 0x54 and magic_bytes[3] == 0x46:
			detected_format = "glb"
		elif magic_bytes[0] == 0x50 and magic_bytes[1] == 0x4B:
			detected_format = "zip"
	if detected_format.is_empty():
		return
	match detected_format:
		"glb", "gltf":
			_import_gltf(file_path, json_payload.name)
		"zip":
			_import_zip(file_path, json_payload.name)

func _import_gltf(file_path, name):
	if not editor_interface:
		return
	var edited_scene_root = editor_interface.get_edited_scene_root()
	if not edited_scene_root:
		return
<<<<<<< HEAD:addons/meshy-godot-plugin/main_scripts.gd
		
	print("场景根节点: ", edited_scene_root.name)
	
	# 创建容器节点
	var container = Node3D.new()
	container.name = "Meshy_" + (name if name else "Model")
	
	# 添加到当前场景
	edited_scene_root.add_child(container)
	container.owner = edited_scene_root
	
	# 使用ResourceLoader加载场景
	print("加载模型: ", file_path)
=======
>>>>>>> d72310ff8ac926fe5396a443837d85f19619cf1f:meshy-godot-plugin/main_scripts.gd
	var resource = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REUSE)
	if resource:
<<<<<<< HEAD:addons/meshy-godot-plugin/main_scripts.gd
		print("资源加载成功: ", resource.get_class())
		
		# 根据资源类型进行处理
		if resource is PackedScene:
			# 实例化场景
			var scene_instance = resource.instantiate()
			print("场景实例化成功: ", scene_instance.get_class())
			
			# 添加到容器
			container.add_child(scene_instance)
			
			# 递归设置所有节点的所有权为场景根
			_recursive_set_owner(scene_instance, edited_scene_root)
			
			# 将实例保存为场景中的本地资源
			print("将实例转换为本地资源")
			scene_instance.owner = edited_scene_root
			
			# 将动画和材质等资源转为本地
			_make_resources_local(scene_instance)
		else:
			print("资源不是PackedScene类型，无法实例化")
			container.queue_free()
			return
	else:
		print("资源加载失败，尝试使用GLTFDocument")
		
=======
		var scene_instance
		if resource is PackedScene:
			scene_instance = resource.instantiate()
		else:
			return
		var node3d = Node3D.new()
		node3d.name = "Meshy_" + (name if name else "Model")
		edited_scene_root.add_child(node3d)
		node3d.owner = edited_scene_root
		node3d.add_child(scene_instance)
		_recursive_set_owner(scene_instance, edited_scene_root)
		editor_interface.get_selection().clear()
		editor_interface.get_selection().add_node(node3d)
	else:
>>>>>>> d72310ff8ac926fe5396a443837d85f19619cf1f:meshy-godot-plugin/main_scripts.gd
		var gltf = GLTFDocument.new()
		var state = GLTFState.new()
		var error = gltf.append_from_file(file_path, state)
		if error == OK:
			var scene = gltf.generate_scene(state)
			if scene:
<<<<<<< HEAD:addons/meshy-godot-plugin/main_scripts.gd
				# 添加到容器
				container.add_child(scene)
				
				# 设置所有权
				_recursive_set_owner(scene, edited_scene_root)
				
				# 将动画和材质等资源转为本地
				_make_resources_local(scene)
				
				print("GLTFDocument导入成功")
			else:
				print("错误: 场景生成失败")
				container.queue_free()
				return
		else:
			print("导入GLTF/GLB失败，错误码: ", error)
			container.queue_free()
			return
	
	# 通知编辑器刷新和选择新节点
	editor_interface.get_selection().clear()
	editor_interface.get_selection().add_node(container)
	
	# 标记场景为已修改，以便保存
	edited_scene_root.set_meta("__editor_changed", true)
	
	print("导入GLTF/GLB成功: ", file_path)

# 将节点及其子节点中的所有资源转为本地资源
func _make_resources_local(node):
	# 检查并处理动画播放器
	if node is AnimationPlayer:
		_make_animations_local(node)
	
	# 处理网格实例
	if node is MeshInstance3D:
		_make_mesh_local(node)
	
	# 递归处理所有子节点
	for child in node.get_children():
		_make_resources_local(child)

# 将动画播放器中的动画转为本地资源
func _make_animations_local(anim_player):
	var animation_names = anim_player.get_animation_list()
	for anim_name in animation_names:
		var animation = anim_player.get_animation(anim_name)
		if animation:
			# 制作动画的副本并替换原始动画
			var local_animation = animation.duplicate()
			anim_player.remove_animation(anim_name)
			anim_player.add_animation(anim_name, local_animation)
			print("动画已转为本地: ", anim_name)

# 将网格实例中的网格和材质转为本地资源
func _make_mesh_local(mesh_instance):
	var mesh = mesh_instance.mesh
	if mesh:
		# 制作网格的副本
		var local_mesh = mesh.duplicate()
		mesh_instance.mesh = local_mesh
		
		# 处理网格中的材质
		var material_count = local_mesh.get_surface_count()
		for i in range(material_count):
			var material = local_mesh.surface_get_material(i)
			if material:
				# 制作材质的副本
				var local_material = material.duplicate()
				local_mesh.surface_set_material(i, local_material)
		
		print("网格和材质已转为本地")
=======
				var node3d = Node3D.new()
				node3d.name = "Meshy_" + (name if name else "Model")
				edited_scene_root.add_child(node3d)
				node3d.owner = edited_scene_root
				
				print("Added container node: ", node3d.name)
				
				node3d.add_child(scene)
				_recursive_set_owner(scene, edited_scene_root)
				
				print("Import complete, node count: ", _count_children(scene))
				
				edited_scene_root.set_meta("__editor_changed", true)
				
				print("GLTF/GLB import successful: ", file_path)
			else:
				print("ERROR: Scene generation failed")
		else:
			print("GLTF/GLB import failed, error code: ", error)
>>>>>>> d72310ff8ac926fe5396a443837d85f19619cf1f:meshy-godot-plugin/main_scripts.gd

func _recursive_set_owner(node, owner):
	for child in node.get_children():
		child.owner = owner
		_recursive_set_owner(child, owner)

func _count_children(node):
	var count = 0
	for child in node.get_children():
		count += 1 + _count_children(child)
	return count

func _import_zip(file_path, name):
	print("Processing ZIP file: ", file_path, " name: ", name)
	
	var zip_reader = ZIPReader.new()
	var err = zip_reader.open(file_path)
	
	if err != OK:
		print("ERROR: Cannot open ZIP file: ", err)
		return

	var files_in_zip = zip_reader.get_files()
	if files_in_zip.is_empty():
		print("WARNING: ZIP file is empty.")
		zip_reader.close()
		return

	var base_extract_dir = "res://imported_models"
	var extract_dir_name = "extracted_%s_%d" % [name, Time.get_unix_time_from_system()]
	var extract_path = base_extract_dir.path_join(extract_dir_name)
	
	var dir_access = DirAccess.open("res://")
	if not dir_access:
		print("ERROR: Cannot access resource directory")
		zip_reader.close()
		return
		
	err = dir_access.make_dir_recursive(extract_path)
	if err != OK:
		print("ERROR: Cannot create extraction directory: ", extract_path, " error code: ", err)
		zip_reader.close()
		return

	print("Extracting to directory: ", extract_path)

	for file_in_zip in files_in_zip:
		var file_data = zip_reader.read_file(file_in_zip)
		var target_file_path = extract_path.path_join(file_in_zip)
		
		var target_dir = target_file_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(target_dir):
			err = dir_access.make_dir_recursive(target_dir)
			if err != OK:
				print("WARNING: Cannot create subdirectory: ", target_dir, " file: ", file_in_zip)
				continue

		var file_access = FileAccess.open(target_file_path, FileAccess.WRITE)
		if file_access:
			file_access.store_buffer(file_data)
			file_access.close()
		else:
			print("ERROR: Cannot write extracted file: ", target_file_path)

	zip_reader.close()
	print("ZIP file extraction complete: ", extract_path)
	
	if editor_interface:
		print("Refreshing file system...")
		var filesystem = editor_interface.get_resource_filesystem()
		if filesystem:
			filesystem.scan()
			print("File system scan triggered.")
		else:
			print("WARNING: Cannot get file system interface.")
	else:
		print("WARNING: editor_interface is null, cannot trigger file system scan.")

	var remove_err = DirAccess.remove_absolute(file_path)
	if remove_err == OK:
		print("Successfully deleted original ZIP file: ", file_path)
	else:
		print("ERROR: Failed to delete original ZIP file: ", file_path, " error code: ", remove_err)
