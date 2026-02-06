# res://VFX/Scripts/vfx_projectile.gd
@tool
extends Node3D
class_name VFXProjectile

# -------------------- Editor / lifecycle --------------------

@export var auto_preview_in_editor: bool = false
@export var preview_seed: int = 12368
@export var auto_apply_on_ready: bool = true

# -------------------- Trail glow layer --------------------
# TrailGlow is a second mesh used as a soft glow layer.
# If you move/rotate Trail in the scene, TrailGlow must be kept in lockstep.
@export var trail_glow_enabled: bool = true
@export var trail_glow_follow_trail: bool = true

# -------------------- Rings anchoring --------------------
# Ensures rings are always centered on the head and move with it.
@export var rings_follow_head: bool = true
# If the head mesh pivot is not centered, use the mesh AABB center instead.
@export var rings_anchor_to_head_mesh_center: bool = true

# -------------------- Preset --------------------

@export var preset: VFXPreset:
	set(v):
		_preset = v
		if is_inside_tree():
			_apply_all()
	get:
		return _preset

var _preset: VFXPreset
var _seed_value: int = 0

# -------------------- Scene contract (auto-create missing) --------------------
# Head: MeshInstance3D
# Trail: MeshInstance3D
# TrailGlow: MeshInstance3D
# Sparks: GPUParticles3D
# Rings: Node3D with RingA / RingB MeshInstance3D

@onready var _head: MeshInstance3D = _ensure_mesh("Head", self)
@onready var _trail: MeshInstance3D = _ensure_mesh("Trail", self)
@onready var _trail_glow: MeshInstance3D = _ensure_mesh("TrailGlow", self)
@onready var _sparks: GPUParticles3D = _ensure_particles("Sparks", self)

@onready var _rings_root: Node3D = _ensure_node3d("Rings", self)
@onready var _ring_a: MeshInstance3D = _ensure_mesh("RingA", _rings_root)
@onready var _ring_b: MeshInstance3D = _ensure_mesh("RingB", _rings_root)

# -------------------- Runtime resources --------------------

var _noise_tex: Texture2D
var _head_mat: ShaderMaterial
var _trail_mat: ShaderMaterial
var _trail_glow_mat: ShaderMaterial
var _spark_mat: ShaderMaterial
var _ring_mat_a: ShaderMaterial
var _ring_mat_b: ShaderMaterial

const _RING_RADIUS_UV: float = 0.78

# -------------------- Shaders (embedded) --------------------

const _SH_HEAD: String = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform sampler2D noise_tex : source_color;
uniform vec4 base_color : source_color = vec4(1.0, 0.45, 0.1, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.95, 0.6, 1.0);
uniform float emissive = 2.5;

uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_scroll = vec2(0.6, 0.0);

uniform float distort_amount = 0.12;
uniform float distort_speed = 5.0;

float core_mask(vec2 uv){
	float cx = 1.0 - abs(uv.x - 0.5) * 2.0;
	float cy = 1.0 - abs(uv.y - 0.5) * 2.0;
	return pow(clamp(cx * cy, 0.0, 1.0), 2.2);
}

void vertex(){
	vec2 uv = fract(UV * uv_scale + TIME * uv_scroll);
	float n = texture(noise_tex, uv).r * 2.0 - 1.0;
	float pulse = 0.6 + 0.4 * sin(TIME * distort_speed);
	VERTEX += NORMAL * (n * distort_amount * pulse);
}

void fragment(){
	vec2 uv = fract(UV * uv_scale + TIME * uv_scroll);
	float n = texture(noise_tex, uv).r;

	float c = core_mask(UV);
	vec3 col = mix(base_color.rgb, core_color.rgb, c);

	float a = n;

	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_TRAIL: String = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform sampler2D noise_tex : source_color;

uniform vec4 base_color : source_color = vec4(1.0, 0.45, 0.1, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.95, 0.6, 1.0);
uniform float emissive = 2.0;

uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_scroll = vec2(1.2, 0.0);
uniform vec2 uv_scroll2 = vec2(-0.4, 0.0);

uniform float width_start = 1.0;
uniform float width_end = 0.05;

uniform float distort_amount = 0.08;
uniform float distort_speed = 2.5;

uniform float alpha = 1.0;

void vertex(){
	// taper along UV.y (0..1)
	float t = clamp(UV.y, 0.0, 1.0);
	float w = mix(width_start, width_end, t);
	VERTEX.x *= w;

	// subtle normal displacement
	vec2 uv = fract(UV * uv_scale + TIME * (uv_scroll * 0.15));
	float n = texture(noise_tex, uv).r * 2.0 - 1.0;
	float pulse = 0.35 + 0.65 * sin(TIME * distort_speed);
	VERTEX += NORMAL * n * distort_amount * pulse;
}

void fragment(){
	vec2 uv0 = fract(UV * uv_scale + TIME * uv_scroll);
	vec2 uv1 = fract(UV * (uv_scale * 1.7) + TIME * uv_scroll2);

	float n0 = texture(noise_tex, uv0).r;
	float n1 = texture(noise_tex, uv1).r;
	float flow = mix(n0, n1, 0.5);

	// brighter core down the center
	float center = 1.0 - abs(UV.x - 0.5) * 2.0;
	center = clamp(center, 0.0, 1.0);
	float core = pow(center, 2.8);

	// fade toward tail end
	float tail = 1.0 - UV.y;
	float a = flow * tail;

	// soften edges
	float edge = smoothstep(0.0, 0.08, UV.x) * smoothstep(0.0, 0.08, 1.0 - UV.x);
	a *= edge;
	a *= alpha;

	vec3 col = mix(base_color.rgb, core_color.rgb, core);

	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_SPARK: String = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform sampler2D noise_tex : source_color;
uniform float emissive = 2.0;
uniform vec2 uv_scroll = vec2(2.2, 0.0);
uniform float soft_edge = 0.25;

void fragment(){
	// soft circular sprite
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float circle = 1.0 - smoothstep(1.0 - soft_edge, 1.0, r);

	// animated noise alpha
	vec2 uv = fract(UV + TIME * uv_scroll);
	float n = texture(noise_tex, uv).r;

	float a = circle * n;

	vec3 col = COLOR.rgb; // driven by particle color / ramp
	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_RING: String = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float emissive = 2.5;

uniform float ring_radius_uv = 0.78;
uniform float thickness = 0.018;
uniform float glow = 0.055;

uniform float pulse_amount = 0.06;
uniform float pulse_speed = 3.0;
uniform float phase = 0.0;

float ring_line(float r, float target_r, float t, float g) {
	float d = abs(r - target_r);
	return 1.0 - smoothstep(t, t + g, d);
}

void fragment(){
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);

	float pr = ring_radius_uv + sin(TIME * pulse_speed + phase) * pulse_amount;

	float a0 = ring_line(r, pr, thickness, glow);
	float a1 = ring_line(r, pr * 0.88, thickness * 0.85, glow);
	float a = max(a0, a1);

	// soften near quad edge
	float edge = 1.0 - smoothstep(0.98, 1.10, r);
	a *= edge;

	vec3 col = ring_color.rgb;
	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

# -------------------- Public API --------------------

func apply_seed(seed_value: int) -> void:
	_seed_value = seed_value
	_apply_all()

func apply_preset(p: VFXPreset, seed_value: int = -1) -> void:
	preset = p
	if seed_value >= 0:
		_seed_value = seed_value
	_apply_all()

# -------------------- Lifecycle --------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		if auto_preview_in_editor and auto_apply_on_ready:
			_seed_value = preview_seed
			_apply_all()
	else:
		if auto_apply_on_ready:
			_seed_value = preview_seed
			_apply_all()

func _process(delta: float) -> void:
	# Keep rings perfectly centered on the head (or mesh center)
	if rings_follow_head:
		_sync_rings_to_head_center()

	_face_rings_to_camera()
	_spin_rings(delta)

	# Keep glow mesh from sitting at origin / looking like a second trail at the head
	if trail_glow_follow_trail:
		_sync_trail_glow_to_trail()

# -------------------- Apply all --------------------

func _apply_all() -> void:
	if _preset == null:
		return

	_noise_tex = _build_noise_texture(_preset.noise_size, _preset.noise_frequency, _seed_value)

	_apply_head()
	_apply_trail()
	_apply_rings()
	_apply_sparks_ring()

# -------------------- Head --------------------

func _apply_head() -> void:
	var base_col: Color = _pick_color(0.55)
	var core_col: Color = _pick_color(0.85)

	var sh: Shader = Shader.new()
	sh.code = _SH_HEAD

	_head_mat = ShaderMaterial.new()
	_head_mat.shader = sh
	_head_mat.set_shader_parameter("noise_tex", _noise_tex)
	_head_mat.set_shader_parameter("base_color", base_col)
	_head_mat.set_shader_parameter("core_color", core_col)
	_head_mat.set_shader_parameter("emissive", _preset.emiss_energy_head)
	_head_mat.set_shader_parameter("uv_scale", _preset.uv_scale)
	_head_mat.set_shader_parameter("uv_scroll", _preset.uv_scroll * 0.5)
	_head_mat.set_shader_parameter("distort_amount", _preset.head_distort_amount)
	_head_mat.set_shader_parameter("distort_speed", _preset.head_distort_speed)

	_head.material_override = _head_mat
	_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# -------------------- Trail --------------------

func _apply_trail() -> void:
	var base_col: Color = _pick_color(0.55)
	var core_col: Color = _pick_color(0.85)

	var sh: Shader = Shader.new()
	sh.code = _SH_TRAIL

	_trail_mat = ShaderMaterial.new()
	_trail_mat.shader = sh
	_trail_mat.set_shader_parameter("noise_tex", _noise_tex)
	_trail_mat.set_shader_parameter("base_color", base_col)
	_trail_mat.set_shader_parameter("core_color", core_col)
	_trail_mat.set_shader_parameter("emissive", _preset.emiss_energy_trail)
	_trail_mat.set_shader_parameter("uv_scale", _preset.uv_scale)
	_trail_mat.set_shader_parameter("uv_scroll", _preset.uv_scroll)
	_trail_mat.set_shader_parameter("uv_scroll2", _preset.secondary_scroll)
	_trail_mat.set_shader_parameter("width_start", _preset.trail_width_start)
	_trail_mat.set_shader_parameter("width_end", _preset.trail_width_end)
	_trail_mat.set_shader_parameter("distort_amount", _preset.head_distort_amount * 0.6)
	_trail_mat.set_shader_parameter("distort_speed", _preset.head_distort_speed * 0.6)
	_trail_mat.set_shader_parameter("alpha", 1.0)

	_trail.material_override = _trail_mat
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	if not trail_glow_enabled:
		_trail_glow.visible = false
		return

	_trail_glow.visible = true

	_trail_glow_mat = _trail_mat.duplicate(true) as ShaderMaterial
	_trail_glow_mat.set_shader_parameter("emissive", _preset.emiss_energy_trail * 0.75)
	_trail_glow_mat.set_shader_parameter("width_start", _preset.trail_width_start * 1.6)
	_trail_glow_mat.set_shader_parameter("width_end", max(0.02, _preset.trail_width_end * 1.8))
	_trail_glow_mat.set_shader_parameter("alpha", 0.55)

	_trail_glow.material_override = _trail_glow_mat
	_trail_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Mirror mesh if TrailGlow has none
	if _trail_glow.mesh == null and _trail.mesh != null:
		_trail_glow.mesh = _trail.mesh.duplicate(true)

	_sync_trail_glow_to_trail()

func _sync_trail_glow_to_trail() -> void:
	if not trail_glow_enabled:
		return
	if _trail == null or _trail_glow == null:
		return
	_trail_glow.transform = _trail.transform

# -------------------- Rings --------------------

func _apply_rings() -> void:
	if not _preset.rings_enabled:
		_rings_root.visible = false
		return

	_rings_root.visible = true

	# Ensure ring instances are centered at the root
	_ring_a.position = Vector3.ZERO
	_ring_b.position = Vector3.ZERO

	# Size quad so world radius matches shader UV radius
	var half: float = _preset.ring_radius_m / _RING_RADIUS_UV
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(half * 2.0, half * 2.0)

	_ring_a.mesh = quad
	_ring_b.mesh = quad.duplicate(true)

	var ring_col: Color = _pick_color(0.65)

	var sh: Shader = Shader.new()
	sh.code = _SH_RING

	_ring_mat_a = ShaderMaterial.new()
	_ring_mat_a.shader = sh
	_ring_mat_a.set_shader_parameter("ring_color", ring_col)
	_ring_mat_a.set_shader_parameter("emissive", _preset.emiss_energy_rings)
	_ring_mat_a.set_shader_parameter("thickness", _preset.ring_thickness)
	_ring_mat_a.set_shader_parameter("pulse_amount", _preset.ring_pulse_amount)
	_ring_mat_a.set_shader_parameter("pulse_speed", _preset.ring_pulse_speed)
	_ring_mat_a.set_shader_parameter("phase", 0.0)

	_ring_mat_b = ShaderMaterial.new()
	_ring_mat_b.shader = sh
	_ring_mat_b.set_shader_parameter("ring_color", ring_col.lightened(0.15))
	_ring_mat_b.set_shader_parameter("emissive", _preset.emiss_energy_rings * 0.9)
	_ring_mat_b.set_shader_parameter("thickness", _preset.ring_thickness * 0.85)
	_ring_mat_b.set_shader_parameter("pulse_amount", _preset.ring_pulse_amount * 0.8)
	_ring_mat_b.set_shader_parameter("pulse_speed", _preset.ring_pulse_speed * 1.15)
	_ring_mat_b.set_shader_parameter("phase", 1.7)

	_ring_a.material_override = _ring_mat_a
	_ring_b.material_override = _ring_mat_b

	_ring_a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Place rings correctly immediately
	if rings_follow_head:
		_sync_rings_to_head_center()

func _sync_rings_to_head_center() -> void:
	if _rings_root == null or _head == null:
		return
	if not _rings_root.visible:
		return

	var pos: Vector3 = _head.global_position

	# If head mesh pivot is not centered, use mesh AABB center in mesh-local space.
	if rings_anchor_to_head_mesh_center and _head.mesh != null:
		var aabb: AABB = _head.mesh.get_aabb()
		var center_local: Vector3 = aabb.position + aabb.size * 0.5
		pos = _head.global_transform * center_local

	_rings_root.global_position = pos

func _face_rings_to_camera() -> void:
	if _rings_root == null or not _rings_root.visible:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	# Rotate the ring quads to face the camera (keep them visually circular).
	_ring_a.look_at(cam.global_transform.origin, Vector3.UP)
	_ring_b.look_at(cam.global_transform.origin, Vector3.UP)

func _spin_rings(delta: float) -> void:
	if _rings_root == null or not _rings_root.visible:
		return
	_ring_a.rotate_object_local(Vector3(0, 0, 1), 0.6 * delta)
	_ring_b.rotate_object_local(Vector3(0, 0, 1), -0.45 * delta)

# -------------------- Sparks --------------------

func _apply_sparks_ring() -> void:
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()

	# Billboard GPU particles via node property (NOT ParticleProcessMaterial)
	_sparks.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD

	# Ring emission
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = _preset.ring_radius_m
	pm.emission_ring_height = 0.02

	# Motion
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = _preset.spark_speed_min
	pm.initial_velocity_max = _preset.spark_speed_max

	# Godot 4.5: orbit_velocity is Vector2(min,max)
	pm.orbit_velocity = Vector2(_preset.spark_orbit_min, _preset.spark_orbit_max)
	pm.angular_velocity_min = -6.0
	pm.angular_velocity_max = 6.0

	# Size + spread
	pm.scale_min = _preset.spark_size_min
	pm.scale_max = _preset.spark_size_max
	pm.spread = rad_to_deg(_preset.spark_spread)

	# Color
	if _preset.use_gradient_palette and _preset.gradient != null:
		var ramp: GradientTexture1D = GradientTexture1D.new()
		ramp.gradient = _preset.gradient
		pm.color_ramp = ramp
	else:
		pm.color = _pick_color(0.65)

	_sparks.process_material = pm

	_sparks.one_shot = false
	_sparks.emitting = true
	_sparks.lifetime = _preset.spark_lifetime
	_sparks.amount = max(24, int(_preset.spark_rate * _preset.spark_lifetime))
	_sparks.preprocess = _preset.spark_lifetime
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Draw pass quad + spark shader
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.12, 0.12)

	var sh: Shader = Shader.new()
	sh.code = _SH_SPARK

	_spark_mat = ShaderMaterial.new()
	_spark_mat.shader = sh
	_spark_mat.set_shader_parameter("noise_tex", _noise_tex)
	_spark_mat.set_shader_parameter("emissive", _preset.emiss_energy_sparks)
	_spark_mat.set_shader_parameter("uv_scroll", Vector2(2.2, 0.0))
	_spark_mat.set_shader_parameter("soft_edge", 0.25)

	quad.material = _spark_mat
	_sparks.draw_pass_1 = quad

# -------------------- Helpers --------------------

func _pick_color(t: float) -> Color:
	if _preset.use_gradient_palette and _preset.gradient != null:
		return _preset.gradient.sample(clamp(t, 0.0, 1.0))

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _seed_value

	var h: float = rng.randf_range(_preset.hue_min, _preset.hue_max)
	var s: float = rng.randf_range(_preset.sat_min, _preset.sat_max)
	var v: float = rng.randf_range(_preset.val_min, _preset.val_max)
	return Color.from_hsv(h, s, v, 1.0)

func _build_noise_texture(size: int, freq: float, seed_value: int) -> Texture2D:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = freq / 100.0

	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var n: float = noise.get_noise_2d(float(x), float(y)) # -1..1
			var vv: float = (n * 0.5) + 0.5
			var c: int = int(clamp(vv, 0.0, 1.0) * 255.0)
			img.set_pixel(x, y, Color8(c, c, c, 255))
	return ImageTexture.create_from_image(img)

func _ensure_node3d(node_name: String, parent: Node) -> Node3D:
	var n: Node = parent.get_node_or_null(node_name)
	if n != null and n is Node3D:
		return n as Node3D
	var created: Node3D = Node3D.new()
	created.name = node_name
	parent.add_child(created)
	_set_owner_if_editor(created)
	return created

func _ensure_mesh(node_name: String, parent: Node) -> MeshInstance3D:
	var n: Node = parent.get_node_or_null(node_name)
	if n != null and n is MeshInstance3D:
		return n as MeshInstance3D
	var created: MeshInstance3D = MeshInstance3D.new()
	created.name = node_name
	created.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(created)
	_set_owner_if_editor(created)
	return created

func _ensure_particles(node_name: String, parent: Node) -> GPUParticles3D:
	var n: Node = parent.get_node_or_null(node_name)
	if n != null and n is GPUParticles3D:
		return n as GPUParticles3D
	var created: GPUParticles3D = GPUParticles3D.new()
	created.name = node_name
	parent.add_child(created)
	_set_owner_if_editor(created)
	return created

func _set_owner_if_editor(n: Node) -> void:
	if not Engine.is_editor_hint():
		return
	var o: Node = get_owner()
	if o != null:
		n.owner = o
