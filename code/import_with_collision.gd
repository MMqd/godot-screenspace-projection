@tool
extends EditorScenePostImport

func _post_import(scene: Node) -> Node:
	# New StaticBody root
	var static_body := StaticBody3D.new()
	static_body.name = scene.name

	# Move imported nodes under StaticBody
	for child in scene.get_children():
		scene.remove_child(child)
		static_body.add_child(child)
		child.owner = static_body

	# Generate collisions (children of StaticBody!)
	_add_trimesh_collisions(static_body, static_body)

	return static_body


func _add_trimesh_collisions(root: StaticBody3D, owner: Node) -> void:
	var meshes := _collect_meshes(root)

	for mesh_instance in meshes:
		if not mesh_instance.mesh:
			continue

		var shape := ConcavePolygonShape3D.new()
		shape.data = mesh_instance.mesh.get_faces()

		var collision := CollisionShape3D.new()
		collision.shape = shape
		collision.name = mesh_instance.name + "_Collision"

		# Make collision match mesh transform
		collision.transform = root.global_transform.affine_inverse() * mesh_instance.global_transform

		root.add_child(collision)
		collision.owner = owner


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		result.append(node)

	for child in node.get_children():
		result.append_array(_collect_meshes(child))

	return result
