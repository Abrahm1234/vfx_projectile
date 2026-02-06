# res://VFX/Scripts/vfx_projectile.gd
@tool
extends Node3D
class_name VFXProjectile

# -------------------- Editor / lifecycle --------------------
@export var auto_preview_in_editor: bool = false
@export var preview_seed: int = 12368
@export var auto_apply_on_ready: bool = true

# -------------------- Trail glow --------------------
@export var trail_glow_enabled: bool = true

# -------------------- Rings --------------------
@export var rings_enabled: bool = true
@export var rings_anchor_to_head_mesh_center: bool = true
@export var rings_local_offset: Vector3 = Vector3.ZERO
@export var rings_face_camera: bool = true

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
@onready var _head: MeshInstance3D = _ensure_mesh("Head", self)
@onready var _trail: MeshInstance3D = _ensure_mesh("Trail", self)
@onready var _sparks: GPUParticles3D = _ensure_particles("Sparks", self)

# Core (NEW) is a child of Head so it always moves with Head perfectly
@onready var _core: MeshInstance3D = _ensure_mesh("Core", _head)

# Rings are a child of Head so they share coordinates and movement with Head
@onready var _rings_root: Node3D = _ensure_node3d("Rings", _head)
@onready var _ring_a: MeshInstance3D = _ensure_mesh("RingA", _rings_root)
@onready var _ring_b: MeshInstance3D = _ensure_mesh("RingB", _rings_root)
@onready var _ring_c: MeshInstance3D = _ensure_mesh("RingC", _rings_root)

# TrailGlow is a child of Trail so it cannot “sit at the head” as a second mesh
@onready var _trail_glow: MeshInstance3D = _ensure_mesh("TrailGlow", _trail)

# -------------------- Runtime resources --------------------
var _noise_tex: Texture2D
var _head_mat: ShaderMaterial
var _core_mat: ShaderMaterial
var _trail_mat: ShaderMaterial
var _trail_glow_mat: ShaderMaterial
var _spark_mat: ShaderMaterial
var _ring_mat: ShaderMaterial

const _RING_RADIUS_UV: float = 0.78

# -------------------- Shaders --------------------
const _SH_HEAD := """
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

const _SH_CORE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform sampler2D noise_tex : source_color;
uniform vec4 core_color : source_color = vec4(1.0, 0.95, 0.7, 1.0);
uniform float emissive = 3.0;

uniform vec2 uv_scale = vec2(1.5, 1.5);
uniform vec2 uv_scroll = vec2(0.35, 0.25);

uniform float distort_amount = 0.06;
uniform float distort_speed = 2.5;

float center_mask(vec2 uv){
	float cx = 1.0 - abs(uv.x - 0.5) * 2.0;
	float cy = 1.0 - abs(uv.y - 0.5) * 2.0;
	return pow(clamp(cx * cy, 0.0, 1.0), 2.2);
}

void vertex(){
	vec2 uv = fract(UV * uv_scale + TIME * uv_scroll);
	float n = texture(noise_tex, uv).r * 2.0 - 1.0;
	float pulse = 0.7 + 0.3 * sin(TIME * distort_speed);
	VERTEX += NORMAL * (n * distort_amount * pulse);
}

void fragment(){
	vec2 uv = fract(UV * uv_scale + TIME * uv_scroll);
	float n = texture(noise_tex, uv).r;

	float c = center_mask(UV);
	float a = mix(0.35, 1.0, c) * (0.5 + 0.5 * n);

	vec3 col = core_color.rgb;

	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_TRAIL := """
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
	float t = clamp(UV.y, 0.0, 1.0);
	float w = mix(width_start, width_end, t);
	VERTEX.x *= w;

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

	float center = 1.0 - abs(UV.x - 0.5) * 2.0;
	center = clamp(center, 0.0, 1.0);
	float core = pow(center, 2.8);

	float tail = 1.0 - UV.y;
	float a = flow * tail;

	float edge = smoothstep(0.0, 0.08, UV.x) * smoothstep(0.0, 0.08, 1.0 - UV.x);
	a *= edge;
	a *= alpha;

	vec3 col = mix(base_color.rgb, core_color.rgb, core);

	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_SPARK := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform sampler2D noise_tex : source_color;
uniform float emissive = 2.0;
uniform vec2 uv_scroll = vec2(2.2, 0.0);
uniform float soft_edge = 0.25;

void fragment(){
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float circle = 1.0 - smoothstep(1.0 - soft_edge, 1.0, r);

	vec2 uv = fract(UV + TIME * uv_scroll);
	float n = texture(noise_tex, uv).r;

	float a = circle * n;

	vec3 col = COLOR.rgb;
	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_SPARK_TRAIL := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform sampler2D noise_tex : source_color;
uniform float emissive = 2.0;
uniform vec2 uv_scroll = vec2(1.8, 0.0);

void fragment(){
	// Assumes UV.y runs along the trail length (0=head, 1=tail). If inverted, swap to UV.y.
	float t = 1.0 - UV.y;

	float n = texture(noise_tex, fract(UV * 2.2 + TIME * uv_scroll)).r;
	float a = (t * t) * (0.35 + 0.65 * n);

	vec3 col = COLOR.rgb; // uses particle color ramp
	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

const _SH_RING := """
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

	float edge = 1.0 - smoothstep(0.98, 1.10, r);
	a *= edge;

	vec3 col = ring_color.rgb;
	ALBEDO = col;
	EMISSION = col * emissive * a;
	ALPHA = a;
}
"""

# -------------------- Lifecycle --------------------
func _ready() -> void:
	_ensure_hierarchy()

	if Engine.is_editor_hint():
		if auto_preview_in_editor and auto_apply_on_ready:
			_seed_value = preview_seed
			_apply_all()
	else:
		if auto_apply_on_ready:
			_seed_value = preview_seed
			_apply_all()

func _process(delta: float) -> void:
	_sync_rings_to_head_center()

	if rings_face_camera:
		_face_rings_to_camera()

	_spin_rings(delta)

# -------------------- Apply all --------------------
func _apply_all() -> void:
	if _preset == null:
		return

	_ensure_hierarchy()
	_noise_tex = _get_or_build_noise_texture()

	_apply_head()
	_apply_core()
	_apply_trail()
	_apply_rings()
	_apply_sparks_ring()

	_sync_rings_to_head_center()

# -------------------- Head --------------------
func _apply_head() -> void:
	var base_col: Color = _pick_color(0.55)
	var core_col: Color = _pick_color(0.85)

	var sh := Shader.new()
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

# -------------------- Inner Core (NEW; driven by preset) --------------------
func _apply_core() -> void:
	_core.visible = _preset.core_enabled
	if not _preset.core_enabled:
		return

	# Mesh assignment (preset-managed)
	if _preset.core_mesh != null:
		_core.mesh = _preset.core_mesh
	elif _core.mesh == null:
		var s := SphereMesh.new()
		s.radius = 1.0
		_core.mesh = s

	# Anchor to mesh center so it stays inside even if head pivot is offset
	var center_local := _head_center_local()
	_core.position = center_local + _preset.core_local_offset
	_core.rotation = Vector3.ZERO

	# Scale relative to head size
	var head_r := 1.0
	if _head.mesh != null:
		var haabb: AABB = _head.mesh.get_aabb()
		var half: Vector3 = haabb.size * 0.5
		head_r = max(0.001, min(half.x, min(half.y, half.z)))

	var base_r := 1.0
	if _core.mesh != null:
		var caabb: AABB = _core.mesh.get_aabb()
		base_r = max(0.001, min(caabb.size.x, min(caabb.size.y, caabb.size.z)) * 0.5)

	var target_r: float = head_r * _preset.core_scale_ratio
	var s_factor: float = target_r / base_r
	_core.scale = Vector3.ONE * s_factor

	var col: Color = _preset.core_color_override
	if _preset.core_use_palette_color:
		col = _pick_color(0.9)

	var sh := Shader.new()
	sh.code = _SH_CORE

	_core_mat = ShaderMaterial.new()
	_core_mat.shader = sh
	_core_mat.set_shader_parameter("noise_tex", _noise_tex)
	_core_mat.set_shader_parameter("core_color", col)
	_core_mat.set_shader_parameter("emissive", _preset.emiss_energy_core)
	_core_mat.set_shader_parameter("distort_amount", _preset.core_distort_amount)
	_core_mat.set_shader_parameter("distort_speed", _preset.core_distort_speed)

	# Draw first so it reads “inside”
	_core_mat.render_priority = -1

	_core.material_override = _core_mat
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# -------------------- Trail + Glow --------------------
func _apply_trail() -> void:
	var base_col: Color = _pick_color(0.55)
	var core_col: Color = _pick_color(0.85)

	var sh := Shader.new()
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

	_trail_glow.visible = trail_glow_enabled
	if not trail_glow_enabled:
		return

	_trail_glow.transform = Transform3D.IDENTITY # stays glued to Trail
	_trail_glow.mesh = _trail.mesh

	_trail_glow_mat = _trail_mat.duplicate(true) as ShaderMaterial
	_trail_glow_mat.set_shader_parameter("emissive", _preset.emiss_energy_trail_glow)
	_trail_glow_mat.set_shader_parameter("width_start", _preset.trail_width_start * _preset.trail_glow_width_mul)
	_trail_glow_mat.set_shader_parameter("width_end", max(0.02, _preset.trail_width_end * _preset.trail_glow_width_mul))
	_trail_glow_mat.set_shader_parameter("alpha", _preset.trail_glow_alpha)

	_trail_glow.material_override = _trail_glow_mat
	_trail_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# -------------------- Rings --------------------
func _apply_rings() -> void:
	_rings_root.visible = rings_enabled and _preset.rings_enabled
	if not _rings_root.visible:
		return

	_ring_a.position = Vector3.ZERO
	_ring_b.position = Vector3.ZERO
	_ring_c.position = Vector3.ZERO

	var half: float = _preset.ring_radius_m / _RING_RADIUS_UV
	var quad := QuadMesh.new()
	quad.size = Vector2(half * 2.0, half * 2.0)

	_ring_a.mesh = quad
	_ring_b.mesh = quad.duplicate(true)
	_ring_c.mesh = quad.duplicate(true)

	var ring_col: Color = _pick_color(0.65)

	var sh := Shader.new()
	sh.code = _SH_RING

	_ring_mat = ShaderMaterial.new()
	_ring_mat.shader = sh
	_ring_mat.set_shader_parameter("ring_color", ring_col)
	_ring_mat.set_shader_parameter("emissive", _preset.emiss_energy_rings)
	_ring_mat.set_shader_parameter("thickness", _preset.ring_thickness)
	_ring_mat.set_shader_parameter("pulse_amount", _preset.ring_pulse_amount)
	_ring_mat.set_shader_parameter("pulse_speed", _preset.ring_pulse_speed)

	_ring_a.material_override = _ring_mat
	_ring_b.material_override = _ring_mat.duplicate(true)
	_ring_c.material_override = _ring_mat.duplicate(true)

	(_ring_b.material_override as ShaderMaterial).set_shader_parameter("phase", 1.7)
	(_ring_c.material_override as ShaderMaterial).set_shader_parameter("phase", 3.2)

	_ring_a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# Keep ring root exactly on head center (local), so it can never drift from camera orbit
func _sync_rings_to_head_center() -> void:
	if _rings_root == null or not _rings_root.visible:
		return
	_rings_root.rotation = Vector3.ZERO
	_rings_root.scale = Vector3.ONE
	_rings_root.position = _head_center_local() + rings_local_offset

func _face_rings_to_camera() -> void:
	if _rings_root == null or not _rings_root.visible:
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	# Rotate the ring root in-place; position stays anchored to head center
	_rings_root.look_at(cam.global_transform.origin, Vector3.UP)

func _spin_rings(delta: float) -> void:
	if _rings_root == null or not _rings_root.visible:
		return
	if is_instance_valid(_ring_a):
		_ring_a.rotate_object_local(Vector3(0, 0, 1), 0.6 * delta)

	if is_instance_valid(_ring_b):
		_ring_b.rotate_object_local(Vector3(0, 0, 1), -0.45 * delta)

	if is_instance_valid(_ring_c):
		_ring_c.rotate_object_local(Vector3(0, 0, 1), 0.25 * delta)

# -------------------- Sparks (ring emission) --------------------
func _apply_sparks_ring() -> void:
	var pm := ParticleProcessMaterial.new()

	# Billboard via node property (avoids invalid ParticleProcessMaterial billboard assignments)
	_sparks.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD

	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = _preset.ring_radius_m
	pm.emission_ring_height = 0.02

	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = _preset.spark_speed_min
	pm.initial_velocity_max = _preset.spark_speed_max

	pm.orbit_velocity = Vector2(_preset.spark_orbit_min, _preset.spark_orbit_max)
	pm.angular_velocity_min = -6.0
	pm.angular_velocity_max = 6.0

	pm.scale_min = _preset.spark_size_min
	pm.scale_max = _preset.spark_size_max
	pm.spread = rad_to_deg(_preset.spark_spread)

	if _preset.use_gradient_palette and _preset.gradient != null:
		var ramp := GradientTexture1D.new()
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

	var quad := QuadMesh.new()
	quad.size = Vector2(0.12, 0.12)

	var sh := Shader.new()
	sh.code = _SH_SPARK

	_spark_mat = ShaderMaterial.new()
	_spark_mat.shader = sh
	_spark_mat.set_shader_parameter("noise_tex", _noise_tex)
	_spark_mat.set_shader_parameter("emissive", _preset.emiss_energy_sparks)
	_spark_mat.set_shader_parameter("uv_scroll", Vector2(2.2, 0.0))
	_spark_mat.set_shader_parameter("soft_edge", 0.25)

	quad.material = _spark_mat
	_sparks.draw_pass_1 = quad

	# --- Enable per-particle trails (Godot-generated ribbons) ---
	_set_prop_if_exists(_sparks, &"trail_enabled", true)

	# Keep this shorter than particle lifetime for “streaks”
	_set_prop_if_exists(_sparks, &"trail_lifetime", min(_preset.spark_lifetime, 0.35))

	# More sections = smoother curves, more cost
	_set_prop_if_exists(_sparks, &"trail_sections", 16)

	# Optional: a dedicated trail material for wispy fade/noise
	var trail_sh := Shader.new()
	trail_sh.code = _SH_SPARK_TRAIL
	var trail_mat := ShaderMaterial.new()
	trail_mat.shader = trail_sh
	trail_mat.set_shader_parameter("noise_tex", _noise_tex)
	trail_mat.set_shader_parameter("emissive", _preset.emiss_energy_sparks)
	trail_mat.set_shader_parameter("uv_scroll", Vector2(1.8, 0.0))

	_set_prop_if_exists(_sparks, &"trail_material", trail_mat)

# -------------------- Helpers --------------------
func _set_prop_if_exists(o: Object, prop: StringName, value) -> void:
	for p in o.get_property_list():
		if p.name == prop:
			o.set(prop, value)
			return

func apply_seed(seed_value: int) -> void:
	_seed_value = seed_value
	_apply_all()

func apply_preset(p: VFXPreset, seed_value: int = -1) -> void:
	preset = p
	if seed_value >= 0:
		_seed_value = seed_value
	_apply_all()

func _head_center_local() -> Vector3:
	if rings_anchor_to_head_mesh_center and _head != null and _head.mesh != null:
		var aabb: AABB = _head.mesh.get_aabb()
		return aabb.position + aabb.size * 0.5
	return Vector3.ZERO

func _pick_color(t: float) -> Color:
	if _preset.use_gradient_palette and _preset.gradient != null:
		return _preset.gradient.sample(clamp(t, 0.0, 1.0))

	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_value

	var h: float = rng.randf_range(_preset.hue_min, _preset.hue_max)
	var s: float = rng.randf_range(_preset.sat_min, _preset.sat_max)
	var v: float = rng.randf_range(_preset.val_min, _preset.val_max)
	return Color.from_hsv(h, s, v, 1.0)

func _get_or_build_noise_texture() -> Texture2D:
	# If preset provides a noise texture, use it (no property access issues and faster)
	if _preset.noise_texture != null:
		return _preset.noise_texture

	# Robust read (prevents “Invalid access to property noise_size” if the wrong script is assigned)
	var size: int = 256
	var freq: float = 6.0

	var v_size: Variant = _preset.get("noise_size")
	if typeof(v_size) == TYPE_INT:
		size = int(v_size)

	var v_freq: Variant = _preset.get("noise_frequency")
	if typeof(v_freq) == TYPE_FLOAT or typeof(v_freq) == TYPE_INT:
		freq = float(v_freq)

	return _build_noise_texture(size, freq, _seed_value)

func _build_noise_texture(size: int, freq: float, seed_value: int) -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = freq / 100.0

	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var n: float = noise.get_noise_2d(float(x), float(y)) # -1..1
			var vv: float = (n * 0.5) + 0.5
			var c: int = int(clamp(vv, 0.0, 1.0) * 255.0)
			img.set_pixel(x, y, Color8(c, c, c, 255))

	return ImageTexture.create_from_image(img)

func _ensure_hierarchy() -> void:
	# Guarantee intended parenting to prevent “extra mesh at head” issues
	if _trail_glow.get_parent() != _trail:
		_trail_glow.reparent(_trail, true)
	_set_owner_if_editor(_trail_glow)

	if _rings_root.get_parent() != _head:
		_rings_root.reparent(_head, true)
	_set_owner_if_editor(_rings_root)

	if _core.get_parent() != _head:
		_core.reparent(_head, true)
	_set_owner_if_editor(_core)

func _ensure_node3d(node_name: String, parent: Node) -> Node3D:
	var n: Node = parent.get_node_or_null(node_name)
	if n != null and n is Node3D:
		return n as Node3D
	var created := Node3D.new()
	created.name = node_name
	parent.add_child(created)
	_set_owner_if_editor(created)
	return created

func _ensure_mesh(node_name: String, parent: Node) -> MeshInstance3D:
	var n: Node = parent.get_node_or_null(node_name)
	if n != null and n is MeshInstance3D:
		return n as MeshInstance3D
	var created := MeshInstance3D.new()
	created.name = node_name
	created.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(created)
	_set_owner_if_editor(created)
	return created

func _ensure_particles(node_name: String, parent: Node) -> GPUParticles3D:
	var n: Node = parent.get_node_or_null(node_name)
	if n != null and n is GPUParticles3D:
		return n as GPUParticles3D
	var created := GPUParticles3D.new()
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
