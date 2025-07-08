@tool
extends CenterContainer

var bridge_running = false
var tcp_server: TCPServer
var peerTCP: StreamPeerTCP
var server_port = 5325
var editor_interface: EditorInterface

func _ready():
	tcp_server = TCPServer.new()
	
	# 检查editor_interface是否已初始化
	print("_ready: editor_interface initialization status: ", editor_interface != null)

	# update status label
	_update_status_label()

func _process(_delta):
	# process request every frame
	# print(bridge_running, tcp_server, tcp_server.get_local_port(), tcp_server.is_connection_available())
	if bridge_running and tcp_server and tcp_server.is_connection_available():
		peerTCP = tcp_server.take_connection()
	if peerTCP != null:
		# https://docs.godotengine.org/en/stable/classes/class_streampeertcp.html#class-streampeertcp
		_handle_peer_tcp()


func _update_status_label():
	var status_label = $VBoxContainer/StatusLabel
	if status_label:
		status_label.text = "Bridge: " + ("Running" if bridge_running else "Stopped")
	
	# update button text
	var bridge_button = $VBoxContainer/Bridge
	if bridge_button:
		bridge_button.text = "Stop Meshy Bridge" if bridge_running else "Run Meshy Bridge"

func _on_open_meshy_pressed() -> void:
	OS.shell_open("https://www.meshy.ai/")

func _on_run_bridge_pressed():
	bridge_running = !bridge_running
	
	if bridge_running:
		# start server
		var error = tcp_server.listen(server_port)
		if error != OK:
			print("ERROR: cannot start server: ", error)
			bridge_running = false
		else:
			print("Meshy Bridge started, listening on port: ", server_port)
	else:
		# stop server
		tcp_server.stop()
		print("Meshy Bridge stopped")
	
	# update status label
	_update_status_label()

func _handle_peer_tcp():
	# read request
	var status = peerTCP.get_status()
	if status == 3: # STATUS_DISCONNECTED
		peerTCP = null
	elif status == 2: # STATUS_CONNECTED
		var code = peerTCP.poll()
		var bytes := peerTCP.get_available_bytes()
		if bytes > 0:
			var data := peerTCP.get_data(bytes)
			if data[0] == 0: # OK
				var request_str = _bytes_to_string(data[1])
				_handle_http_request(request_str)

func _bytes_to_string(bytes: PackedByteArray) -> String:
	return bytes.get_string_from_ascii()

func _handle_http_request(request_str: String):
	
	# parse HTTP request
	var request_lines = request_str.split("\n")
	if request_lines.is_empty():
		return
	
	# parse request line
	var request_line = request_lines[0].split(" ")
	if request_line.size() < 2:
		return
	
	var method = request_line[0]
	var path = request_line[1]
	# print("HTTP request: ", method, " ", path)

	var response = {}
	
	# handle request
	if method == "GET" and (path == "/status" or path == "/ping"):
		# return status info
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
				# wait 2 seconds
				await get_tree().create_timer(2.0).timeout
				_send_json_response(peerTCP, {
					"status": "ok",
					"message": "File imported successfully"
				}, 200)
		else:
			# return error response
			response = {
				"status": "error",
				"message": "Invalid request format"
			}
			_send_json_response(peerTCP, response, 400)
	else:
		# return 404 response
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
	print("Starting file download: ", json_payload.url, " format: ", json_payload.format)
	
	# download file
	var http = HTTPRequest.new()
	add_child(http)
	# connect signal
	http.connect("request_completed", _on_download_completed.bind(json_payload))
	
	# start download
	var error = http.request(json_payload.url)
	if error != OK:
		print("ERROR: download request failed: ", error)
		http.queue_free()

func _on_download_completed(result, response_code, headers, body, json_payload):
	print("Download completed: result=", result, " response_code=", response_code, " data_size=", body.size())
	
	if result != HTTPRequest.RESULT_SUCCESS:
		print("ERROR: download failed: ", result)
		return
	
	if response_code != 200:
		print("ERROR: download response code error: ", response_code)
		return
	
	# save to project resource directory
	var res_dir = "res://imported_models"
	var dir = DirAccess.open("res://")
	if not dir.dir_exists(res_dir):
		dir.make_dir(res_dir)
	
	var file_name = "meshy_model_" + str(Time.get_unix_time_from_system()) + "." + json_payload.format
	var file_path = res_dir.path_join(file_name)
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		# save file
		file.store_buffer(body)
		file.flush()
		file = null
		
		# ensure file exists and is accessible
		if FileAccess.file_exists(file_path):
			# manually trigger file system scan
			if editor_interface:
				var filesystem = editor_interface.get_resource_filesystem()
				filesystem.scan()
			
			# 使用非await方式等待文件识别
			_wait_for_file_recognition(file_path)
		else:
			print("ERROR: file not found: ", file_path)
	else:
		print("ERROR: cannot save file: ", file_path)

# 修改_wait_for_file_recognition函数，使用Timer和信号而不是await
func _wait_for_file_recognition(file_path: String) -> void:
	print("Waiting for file recognition: ", file_path)
	
	# 如果文件已经存在，直接继续
	if ResourceLoader.exists(file_path):
		print("File recognized: ", file_path)
		_continue_import(file_path)
		return
		
	# 创建定时器
	var timer = Timer.new()
	timer.wait_time = 0.2
	timer.one_shot = false
	add_child(timer)
	
	# 设置计数器
	var retry_count = 0
	var max_retries = 10
	
	# 连接超时信号
	timer.timeout.connect(func():
		retry_count += 1
		print("Waiting for file recognition... Attempts: ", retry_count)
		
		if ResourceLoader.exists(file_path):
			print("File recognized: ", file_path)
			timer.queue_free()
			_continue_import(file_path)
			return
			
		if retry_count >= max_retries:
			print("File recognition timeout!")
			timer.queue_free()
	)
	
	# 启动定时器
	timer.start()

# 添加新函数，继续导入过程
func _continue_import(file_path: String) -> void:
	# 从file_path提取json_payload信息 (仅提取name)
	# var format = file_path.get_extension() # 不再依赖扩展名
	var name = file_path.get_file().get_basename()
	
	var json_payload = {
		# "format": format, # 格式将在_import_model中检测
		"name": name
	}
	
	# 导入模型
	_import_model(file_path, json_payload)

func _import_model(file_path, json_payload):
	print("Preparing to detect and import model: ", file_path)
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		print("ERROR: Cannot open file for type detection: ", file_path)
		return
		
	# 读取文件头部的魔数 (读取更多字节以检测FBX)
	var magic_bytes = file.get_buffer(21) # FBX magic number is 21 bytes long
	file.close() # 检测后关闭文件
	
	var detected_format = ""
	
	if magic_bytes.size() >= 21: # Check for FBX magic number
		# FBX Magic Number: "Kaydara FBX Binary  \x00"
		var fbx_magic = PackedByteArray([0x4B, 0x61, 0x79, 0x64, 0x61, 0x72, 0x61, 0x20, 0x46, 0x42, 0x58, 0x20, 0x42, 0x69, 0x6E, 0x61, 0x72, 0x79, 0x20, 0x20, 0x00])
		if magic_bytes.slice(0, 21) == fbx_magic:
			detected_format = "fbx"
	
	if detected_format.is_empty(): # Only check for GLB and ZIP if FBX isn't detected
		if magic_bytes.size() >= 4:
			# 检查GLB魔数 "glTF" (0x676C5446)
			if magic_bytes[0] == 0x67 and magic_bytes[1] == 0x6C and magic_bytes[2] == 0x54 and magic_bytes[3] == 0x46:
				detected_format = "glb"
			# 检查ZIP魔数 "PK" (0x504B) - 只需要前两个字节
			elif magic_bytes[0] == 0x50 and magic_bytes[1] == 0x4B:
				detected_format = "zip"
			
	if detected_format.is_empty():
		print("ERROR: Unknown or unsupported file format. Magic bytes: ", magic_bytes.hex_encode())
		return

	print("Detected file format: ", detected_format)
	
	# 使用检测到的格式进行处理
	match detected_format:
		"glb", "gltf": # 仍然处理 gltf 以防万一，尽管魔数是 glb
			_import_gltf(file_path, json_payload.name)
		"fbx":
			_import_fbx(file_path, json_payload.name)
		"zip":
			_import_zip(file_path, json_payload.name)
		_:
			print("Unsupported format (logical error): ", detected_format)

func _import_gltf(file_path, name):
	print("Starting GLTF/GLB import")
	
	# 检查编辑器接口
	if not editor_interface:
		print("ERROR: editor_interface is null")
		return
		
	# 检查场景根
	var edited_scene_root = editor_interface.get_edited_scene_root()
	if not edited_scene_root:
		print("ERROR: No open scene")
		return
		
	print("Scene root node: ", edited_scene_root.name)
	
	# 创建容器节点
	var container = Node3D.new()
	container.name = "Meshy_" + (name if name else "Model")
	
	# 添加到当前场景
	edited_scene_root.add_child(container)
	container.owner = edited_scene_root
	
	# 使用ResourceLoader加载场景
	print("Loading model: ", file_path)
	var resource = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REUSE)
	
	if resource:
		print("Resource loaded successfully: ", resource.get_class())
		
		# 根据资源类型进行处理
		if resource is PackedScene:
			# 实例化场景
			var scene_instance = resource.instantiate()
			print("Scene instantiated successfully: ", scene_instance.get_class())
			
			# 添加到容器
			container.add_child(scene_instance)
			
			# 递归设置所有节点的所有权为场景根
			_recursive_set_owner(scene_instance, edited_scene_root)
			
			# 将实例保存为场景中的本地资源
			print("Converting instance to local resource")
			scene_instance.owner = edited_scene_root
			
			# 将动画和材质等资源转为本地
			_make_resources_local(scene_instance)
		else:
			print("Resource is not PackedScene type, cannot instantiate")
			container.queue_free()
			return
	else:
		print("Resource loading failed, attempting with GLTFDocument")
		
		var gltf = GLTFDocument.new()
		var state = GLTFState.new()
		var error = gltf.append_from_file(file_path, state)
		
		if error == OK:
			var scene = gltf.generate_scene(state)
			if scene:
				# 添加到容器
				container.add_child(scene)
				
				# 设置所有权
				_recursive_set_owner(scene, edited_scene_root)
				
				# 将动画和材质等资源转为本地
				_make_resources_local(scene)
				
				print("GLTFDocument import successful")
			else:
				print("ERROR: Scene generation failed")
				container.queue_free()
				return
		else:
			print("GLTF/GLB import failed, error code: ", error)
			container.queue_free()
			return
	
	# 通知编辑器刷新和选择新节点
	editor_interface.get_selection().clear()
	editor_interface.get_selection().add_node(container)
	
	# 标记场景为已修改，以便保存
	edited_scene_root.set_meta("__editor_changed", true)
	
	print("GLTF/GLB import successful: ", file_path)

func _import_fbx(file_path, name):
	print("Starting FBX import")
	
	# 检查编辑器接口
	if not editor_interface:
		print("ERROR: editor_interface is null")
		return
		
	# 检查场景根
	var edited_scene_root = editor_interface.get_edited_scene_root()
	if not edited_scene_root:
		print("ERROR: No open scene")
		return
		
	print("Scene root node: ", edited_scene_root.name)
	
	# 创建容器节点
	var container = Node3D.new()
	container.name = "Meshy_" + (name if name else "Model")
	
	# 添加到当前场景
	edited_scene_root.add_child(container)
	container.owner = edited_scene_root
	
	# 使用ResourceLoader加载场景
	print("Loading model: ", file_path)
	# Godot 4.x has native FBX import support
	
	var resource = null
	var retry_count = 0
	var max_retries = 10 # Max retries
	var retry_delay = 0.2 # seconds
	
	# Try loading the resource with retries
	while retry_count < max_retries:
		resource = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REUSE)
		if resource:
			print("Resource loaded successfully (attempts: ", retry_count + 1, "): ", resource.get_class())
			break # Successfully loaded, exit loop
		
		print("Resource loading failed, retrying... (attempts: ", retry_count + 1, ")")
		retry_count += 1
		await get_tree().create_timer(retry_delay).timeout # Wait before retrying
		
	if resource:
		# 根据资源类型进行处理
		if resource is PackedScene:
			# 实例化场景
			var scene_instance = resource.instantiate()
			print("Scene instantiated successfully: ", scene_instance.get_class())
			
			# 添加到容器
			container.add_child(scene_instance)
			
			# 递归设置所有节点的所有权为场景根
			_recursive_set_owner(scene_instance, edited_scene_root)
			
			# 将实例保存为场景中的本地资源
			print("Converting instance to local resource")
			scene_instance.owner = edited_scene_root
			
			# 将动画和材质等资源转为本地
			_make_resources_local(scene_instance)
		else:
			print("Resource is not PackedScene type, cannot instantiate")
			container.queue_free()
			return
	else:
		print("FBX import failed: Could not load resource (max retries reached). Please ensure FBX importer is correctly set up or the file is valid.")
		container.queue_free()
		return
	
	# 通知编辑器刷新和选择新节点
	editor_interface.get_selection().clear()
	editor_interface.get_selection().add_node(container)
	
	# 标记场景为已修改，以便保存
	edited_scene_root.set_meta("__editor_changed", true)
	
	print("FBX import successful: ", file_path)

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
			print("Animation converted to local: ", anim_name)

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
		
		print("Mesh and materials converted to local")

# 递归设置所有节点的所有权
func _recursive_set_owner(node, owner):
	for child in node.get_children():
		child.owner = owner
		_recursive_set_owner(child, owner)

# 计算子节点数量的辅助函数
func _count_children(node):
	var count = 0
	for child in node.get_children():
		count += 1 + _count_children(child)
	return count

func _import_zip(file_path, name):
	print("Starting ZIP file processing: ", file_path, " name: ", name)
	
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

	# 创建解压目标目录
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

	var fbx_found = false
	var extracted_fbx_path = ""

	# 提取文件
	for file_in_zip in files_in_zip:
		var file_data = zip_reader.read_file(file_in_zip)
		var target_file_path = extract_path.path_join(file_in_zip)
		
		# 确保目标文件的父目录存在 (处理ZIP内的目录结构)
		var target_dir = target_file_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(target_dir):
			err = dir_access.make_dir_recursive(target_dir)
			if err != OK:
				print("WARNING: Cannot create subdirectory: ", target_dir, " file: ", file_in_zip)
				continue # 跳过这个文件

		# 写入文件
		var file_access = FileAccess.open(target_file_path, FileAccess.WRITE)
		if file_access:
			file_access.store_buffer(file_data)
			file_access.close()
			print("Extracted: ", target_file_path)
			
			# 检查是否是FBX文件
			if file_in_zip.get_extension().to_lower() == "fbx":
				fbx_found = true
				extracted_fbx_path = target_file_path
		else:
			print("ERROR: Cannot write extracted file: ", target_file_path)

	zip_reader.close()
	print("ZIP file extraction complete: ", extract_path)
	
	# 手动触发文件系统扫描以确保编辑器识别新文件
	if editor_interface:
		print("Refreshing file system...")
		var filesystem = editor_interface.get_resource_filesystem()
		if filesystem:
			filesystem.scan()
			print("File system scan triggered.")
		else:
			print("WARNING: Could not get file system interface.")
	else:
		print("WARNING: editor_interface is null, cannot trigger file system scan.")

	# 如果在ZIP中找到FBX文件，则导入它
	if fbx_found:
		print("FBX file found in ZIP, starting import: ", extracted_fbx_path)
		# 调用 _wait_for_file_recognition 等待FBX文件被识别
		_wait_for_file_recognition(extracted_fbx_path)
	else:
		print("WARNING: No FBX model found in ZIP. Skipping model import.")
	
	# 删除原始的（可能错误命名的）ZIP文件
	var remove_err = DirAccess.remove_absolute(file_path)
	if remove_err == OK:
		print("Successfully deleted original ZIP file: ", file_path)
	else:
		print("ERROR: Failed to delete original ZIP file: ", file_path, " error code: ", remove_err)

	
