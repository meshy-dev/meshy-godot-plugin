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
	print("_ready: editor_interface初始化状态: ", editor_interface != null)

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
	print("开始下载文件: ", json_payload.url, " 格式: ", json_payload.format)
	
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
	print("下载完成: 结果=", result, " 响应码=", response_code, " 数据大小=", body.size())
	
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
	print("等待文件识别: ", file_path)
	
	# 如果文件已经存在，直接继续
	if ResourceLoader.exists(file_path):
		print("文件已识别: ", file_path)
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
		print("等待文件识别中... 尝试次数: ", retry_count)
		
		if ResourceLoader.exists(file_path):
			print("文件已识别: ", file_path)
			timer.queue_free()
			_continue_import(file_path)
			return
			
		if retry_count >= max_retries:
			print("文件识别超时!")
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
	print("准备检测并导入模型: ", file_path)
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		print("错误: 无法打开文件进行类型检测: ", file_path)
		return
		
	# 读取文件头部的魔数
	var magic_bytes = file.get_buffer(4)
	file.close() # 检测后关闭文件
	
	var detected_format = ""
	
	if magic_bytes.size() >= 4:
		# 检查GLB魔数 "glTF" (0x676C5446)
		if magic_bytes[0] == 0x67 and magic_bytes[1] == 0x6C and magic_bytes[2] == 0x54 and magic_bytes[3] == 0x46:
			detected_format = "glb"
		# 检查ZIP魔数 "PK" (0x504B) - 只需要前两个字节
		elif magic_bytes[0] == 0x50 and magic_bytes[1] == 0x4B:
			detected_format = "zip"
			
	if detected_format.is_empty():
		# 如果无法识别，尝试使用原始payload中的格式（作为后备）
		# 或者直接报错
		print("错误: 未知的或不支持的文件格式. 魔数: ", magic_bytes.hex_encode())
		# 如果json_payload包含原始格式，可以在这里使用它作为后备
		# if json_payload.has("format"):
		#    detected_format = json_payload.format
		# else:
		#    return # 或者直接返回
		return

	print("检测到的文件格式: ", detected_format)
	
	# 使用检测到的格式进行处理
	match detected_format:
		"glb", "gltf": # 仍然处理 gltf 以防万一，尽管魔数是 glb
			_import_gltf(file_path, json_payload.name)
		"zip":
			_import_zip(file_path, json_payload.name)
		_:
			print("不支持的格式（逻辑错误）: ", detected_format)

func _import_gltf(file_path, name):
	print("开始导入GLTF/GLB")
	
	# 检查编辑器接口
	if not editor_interface:
		print("错误: editor_interface为null")
		return
		
	# 检查场景根
	var edited_scene_root = editor_interface.get_edited_scene_root()
	if not edited_scene_root:
		print("错误: 没有打开的场景")
		return
		
	print("场景根节点: ", edited_scene_root.name)
	
	# 使用ResourceLoader加载场景
	print("尝试直接使用ResourceLoader加载模型")
	var resource = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REUSE)
	
	if resource:
		print("资源加载成功: ", resource.get_class())
		var scene_instance
		
		# 根据资源类型进行处理
		if resource is PackedScene:
			scene_instance = resource.instantiate()
			print("场景实例化成功: ", scene_instance.get_class())
		else:
			print("资源不是PackedScene类型，无法实例化")
			return
			
		# 创建容器节点
		var node3d = Node3D.new()
		node3d.name = "Meshy_" + (name if name else "Model")
		
		# 添加到当前场景
		edited_scene_root.add_child(node3d)
		node3d.owner = edited_scene_root
		
		# 添加导入的场景
		node3d.add_child(scene_instance)
		_recursive_set_owner(scene_instance, edited_scene_root)
		
		print("模型添加到场景成功")
		
		# 通知编辑器刷新和选择新节点
		editor_interface.get_selection().clear()
		editor_interface.get_selection().add_node(node3d)
		
		print("导入GLTF/GLB成功: ", file_path)
	else:
		print("资源加载失败，尝试使用GLTFDocument")
		
		# 原来的导入逻辑保留为备选方案
		var gltf = GLTFDocument.new()
		var state = GLTFState.new()
		var error = gltf.append_from_file(file_path, state)
		
		if error == OK:
			var scene = gltf.generate_scene(state)
			if scene:
				# 创建容器
				var node3d = Node3D.new()
				node3d.name = "Meshy_" + (name if name else "Model")
				
				# 添加到当前场景
				edited_scene_root.add_child(node3d)
				node3d.owner = edited_scene_root
				
				print("添加容器节点: ", node3d.name)
				
				# 添加导入的场景
				node3d.add_child(scene)
				_recursive_set_owner(scene, edited_scene_root)
				
				print("导入完成，节点数量: ", _count_children(scene))
				
				# 标记场景为已修改，以便保存
				edited_scene_root.set_meta("__editor_changed", true)
				
				print("导入GLTF/GLB成功: ", file_path)
			else:
				print("错误: 场景生成失败")
		else:
			print("导入GLTF/GLB失败，错误码: ", error)

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
	print("开始处理ZIP文件: ", file_path, " 名称: ", name)
	
	var zip_reader = ZIPReader.new()
	var err = zip_reader.open(file_path)
	
	if err != OK:
		print("错误: 无法打开ZIP文件: ", err)
		return

	var files_in_zip = zip_reader.get_files()
	if files_in_zip.is_empty():
		print("警告: ZIP文件为空.")
		zip_reader.close()
		return

	# 创建解压目标目录
	var base_extract_dir = "res://imported_models"
	var extract_dir_name = "extracted_%s_%d" % [name, Time.get_unix_time_from_system()]
	var extract_path = base_extract_dir.path_join(extract_dir_name)
	
	var dir_access = DirAccess.open("res://")
	if not dir_access:
		print("错误: 无法访问资源目录")
		zip_reader.close()
		return
		
	err = dir_access.make_dir_recursive(extract_path)
	if err != OK:
		print("错误: 无法创建解压目录: ", extract_path, " 错误码: ", err)
		zip_reader.close()
		return

	print("解压到目录: ", extract_path)

	# 提取文件
	for file_in_zip in files_in_zip:
		var file_data = zip_reader.read_file(file_in_zip)
		var target_file_path = extract_path.path_join(file_in_zip)
		
		# 确保目标文件的父目录存在 (处理ZIP内的目录结构)
		var target_dir = target_file_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(target_dir):
			err = dir_access.make_dir_recursive(target_dir)
			if err != OK:
				print("警告: 无法创建子目录: ", target_dir, " 文件: ", file_in_zip)
				continue # 跳过这个文件

		# 写入文件
		var file_access = FileAccess.open(target_file_path, FileAccess.WRITE)
		if file_access:
			file_access.store_buffer(file_data)
			file_access.close()
			# print("已解压: ", target_file_path)
		else:
			print("错误: 无法写入解压文件: ", target_file_path)

	zip_reader.close()
	print("ZIP文件解压完成: ", extract_path)
	
	# 手动触发文件系统扫描以确保编辑器识别新文件
	if editor_interface:
		print("正在刷新文件系统...")
		var filesystem = editor_interface.get_resource_filesystem()
		if filesystem:
			filesystem.scan()
			# 等待扫描完成可能需要一点时间，但我们这里不阻塞
			print("文件系统扫描已触发.")
		else:
			print("警告: 无法获取文件系统接口.")
	else:
		print("警告: editor_interface 为 null，无法触发文件系统扫描.")

	# 注意：ZIP文件只解压，不执行场景导入操作。
	
	# 删除原始的（可能错误命名的）ZIP文件
	var remove_err = DirAccess.remove_absolute(file_path)
	if remove_err == OK:
		print("已成功删除原始ZIP文件: ", file_path)
	else:
		print("错误: 删除原始ZIP文件失败: ", file_path, " 错误码: ", remove_err)

	
