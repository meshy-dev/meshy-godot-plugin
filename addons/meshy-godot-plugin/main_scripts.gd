@tool
extends CenterContainer

var bridge_running = false
var tcp_server: TCPServer
var peerTCP: StreamPeerTCP
var server_port = 5325
var editor_interface: EditorInterface

func _ready():
	tcp_server = TCPServer.new()

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
	# print("processing info: ", json_payload)
	
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
				filesystem.scan_sources()
			# wait for file recognition
			await _wait_for_file_recognition(file_path)

			
			# import model
			_import_model(file_path, json_payload)
		else:
			print("ERROR: file not found: ", file_path)
	else:
		print("ERROR: cannot save file: ", file_path)

# wait for file recognition
func _wait_for_file_recognition(file_path: String) -> void:
	var max_retries = 10
	var retry_delay = 0.2
	
	for i in range(max_retries):
		if ResourceLoader.exists(file_path):
			return
		await get_tree().create_timer(retry_delay).timeout
	

func _import_model(file_path, json_payload):
	match json_payload.format:
		"glb", "gltf":
			_import_gltf(file_path, json_payload.name)
		"zip":
			_import_zip(file_path, json_payload.name)
		_:
			print("不支持的格式: ", json_payload.format)
	

func _import_gltf(file_path, name):
	
	var gltf = GLTFDocument.new()
	var state = GLTFState.new()
	var error = gltf.append_from_file(file_path, state)
	# TODO: import to active scene
	if error == OK:
		var scene = gltf.generate_scene(state)
		if scene:
			# create a new node3d
			var node3d = Node3D.new()
			node3d.name = "Meshy_" + name if name else "Meshy_Model"
			node3d.add_child(scene)
			node3d.owner = get_tree().get_root()
			node3d.visible = true
			
			get_tree().get_current_scene().add_child(node3d)
			print("导入GLTF/GLB成功: ", file_path)
	else:
		print("导入GLTF/GLB失败: ", error)

func _import_zip(file_path, name):
	# TODO: unzip and import glb
	print("导入ZIP: ", file_path, " 名称: ", name)
	
	
