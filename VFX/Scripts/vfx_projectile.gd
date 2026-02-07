@tool
extends Node3D
class_name VFXProjectile

# Scene expectations (auto-created if missing):
# - Head   : MeshInstance3D
# - Trail  : MeshInstance3D
# - Sparks : GPUParticles3D
# Additional nodes this script creates/maintains:
# - Core      : MeshInstance3D
# - CoreInner : MeshInstance3D
# - Rings     : MeshInstance3D (billboarded to camera if enabled)

# -----------------------------
# Preview / control
# -----------------------------
@export var auto_preview_in_editor: bool = true
@export var preview_seed: int = 12368
@export var auto_apply_on_ready: bool = true
@export var randomize_seed_on_ready: bool = true

@export var preset: Resource # should be VFXPreset

# Component toggles (in addition to preset enables)
@export var core_enabled: bool = true
@export var head_enabled: bool = true
@export var trail_enabled: bool = true
@export var rings_enabled: bool = true
@export var sparks_enabled: bool = true

# Rings behavior
@export var rings_anchor_to_head: bool = true
@export var rings_face_camera: bool = true
@export var rings_local_offset: Vector3 = Vector3.ZERO
@export var rings_spin_speed: float = 1.0

# Rings sizing + breathing
@export var rings_quad_size: float = 1.0
@export var rings_min_radius: float = 0.60
@export var rings_max_radius: float = 0.92
@export var rings_breath_amount: float = 0.08
@export var rings_breath_speed: float = 1.2

# Rings pulse (brightness)
@export var rings_pulse_base: float = 0.85
@export var rings_pulse_amp: float = 0.25

# Optional rings texture (mask/noise) + animation
@export var rings_texture: Texture2D
@export var rings_tex_uv_scale: Vector2 = Vector2.ONE
@export var rings_tex_scroll: Vector2 = Vector2(0.10, -0.08)
@export var rings_tex_rotate_speed: float = 0.0
@export_range(0.0, 1.0, 0.01) var rings_tex_strength: float = 0.0

# Color scheme behavior
@export var use_color_schemes: bool = true
@export var separate_component_schemes: bool = true
@export var allow_duplicate_component_schemes: bool = false

# Per-component scheme override: -1 = auto, else 0..5 per enum below
@export_range(-1, 5, 1) var head_scheme_override: int = -1
@export_range(-1, 5, 1) var trail_scheme_override: int = -1
@export_range(-1, 5, 1) var rings_scheme_override: int = -1
@export_range(-1, 5, 1) var sparks_scheme_override: int = -1

# -----------------------------
# Internals / nodes
# -----------------------------
var _seed_value: int = 0

var _head: MeshInstance3D
var _trail: MeshInstance3D
var _sparks: GPUParticles3D

var _core: MeshInstance3D
var _core_inner: MeshInstance3D
var _rings: MeshInstance3D

var _noise_tex: Texture2D

# Per-component chosen colors (derived from core + schemes)
var _col_core: Color = Color.WHITE
var _col_head: Color = Color.WHITE
var _col_trail: Color = Color.WHITE
var _col_rings: Color = Color.WHITE
var _col_sparks: Color = Color.WHITE

var _scheme_head: int = 1
var _scheme_trail: int = 1
var _scheme_rings: int = 1
var _scheme_sparks: int = 1

# Cached materials
var _mat_energy_core: ShaderMaterial
var _mat_energy_inner: ShaderMaterial
var _mat_energy_head: ShaderMaterial
var _mat_energy_trail: ShaderMaterial
var _mat_rings: ShaderMaterial
var _white_tex: Texture2D
var _rings_scale_base: float = 1.0
var _rings_phase: float = 0.0

# -----------------------------
# Color schemes
# -----------------------------
enum ColorScheme {
	MONOCHROMATIC = 0,
	ANALOGOUS = 1,
	COMPLEMENTARY = 2,
	TRIAD = 3,
	SPLIT_COMPLEMENTARY = 4,
	TETRADIC = 5,
}

const _ALL_SCHEMES: Array[int] = [0, 1, 2, 3, 4, 5]

# Deterministic salts (valid hex)
const _SALT_CORE: int   = 0xC0DEC0DE
const _SALT_SCHEME: int = 0x51A7C3A1
const _SALT_HEAD: int   = 0x11EAD001
const _SALT_TRAIL: int  = 0x7A11F00D
const _SALT_RINGS: int  = 0x716E6501
const _SALT_SPARKS: int = 0x5FA4B500

# -----------------------------
# Godot lifecycle
# -----------------------------
func _ready() -> void:
	_seed_value = preview_seed

	_ensure_nodes()

	if Engine.is_editor_hint():
		if auto_preview_in_editor and auto_apply_on_ready:
			apply_seed(preview_seed)
		return

	if randomize_seed_on_ready:
		randomize_seed()
	elif auto_apply_on_ready:
		apply_seed(_seed_value)

func _process(delta: float) -> void:
	if _rings != null and rings_enabled:
		# Anchor (local-space) so it doesn't drift
		var base_pos := rings_local_offset
		if rings_anchor_to_head and _head != null:
			base_pos += _head.position
		_rings.position = base_pos

		# Face camera
		if rings_face_camera:
			var cam: Camera3D = _find_camera()
			if cam != null:
				_rings.look_at(cam.global_position, Vector3.UP)

		# Breathing scale (do AFTER look_at, because look_at can stomp scale)
		var t := float(Time.get_ticks_msec()) * 0.001
		var breath := 1.0 + rings_breath_amount * sin((t + _rings_phase) * TAU * rings_breath_speed)
		_rings.scale = Vector3.ONE * (_rings_scale_base * breath)

		# Spin (optional)
		if absf(rings_spin_speed) > 0.00001:
			_rings.rotate_object_local(Vector3.FORWARD, rings_spin_speed * delta)

# -----------------------------
# Public API
# -----------------------------
func randomize_seed() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	apply_seed(int(rng.randi() & 0x7fffffff))

func apply_seed(seed_value: int) -> void:
	_seed_value = seed_value
	_apply_all()

func apply_preset(new_preset: Resource) -> void:
	preset = new_preset
	_apply_all()

# -----------------------------
# Apply pipeline
# -----------------------------
func _apply_all() -> void:
	_ensure_nodes()
	_noise_tex = _build_noise_texture()
	_rings_phase = float((_mix_seed(_seed_value, _SALT_RINGS) % 1000)) * 0.001

	_assign_scheme_colors()

	_apply_core()
	_apply_head()
	_apply_trail()
	_apply_rings()
	_apply_sparks()

func _apply_core() -> void:
	if _core == null:
		return

	var p_enabled: bool = _p_bool("core_enabled", true)
	_core.visible = core_enabled and p_enabled
	if not _core.visible:
		return

	var m: Mesh = _p_mesh("core_mesh")
	if m != null:
		_core.mesh = m
	_core.scale = Vector3.ONE * _p_float("core_scale", 0.45)

	_mat_energy_core = _make_energy_material(_col_core, _p_float("core_alpha", 0.55), _p_float("core_emission_strength", 1.6))
	_core.material_override = _mat_energy_core

	# Inner core
	if _core_inner != null:
		var inner_enabled: bool = _p_bool("core_inner_enabled", true)
		_core_inner.visible = _core.visible and inner_enabled
		if _core_inner.visible:
			var im: Mesh = _p_mesh("core_inner_mesh")
			if im != null:
				_core_inner.mesh = im
			_core_inner.scale = Vector3.ONE * _p_float("core_inner_scale", 0.30)

			var inner_col: Color = _brighten(_col_core, 1.35)
			_mat_energy_inner = _make_energy_material(inner_col, _p_float("core_inner_alpha", 0.55), _p_float("core_inner_emission_strength", 1.6))
			_core_inner.material_override = _mat_energy_inner

func _apply_head() -> void:
	if _head == null:
		return

	var p_enabled: bool = _p_bool("head_enabled", true)
	_head.visible = head_enabled and p_enabled
	if not _head.visible:
		return

	var m: Mesh = _p_mesh("head_mesh")
	if m != null:
		_head.mesh = m
	_head.scale = Vector3.ONE * _p_float("head_scale", 0.85)

	_mat_energy_head = _make_energy_material(_col_head, _p_float("head_alpha", 0.55), _p_float("head_emission_strength", 1.6))
	_head.material_override = _mat_energy_head

func _apply_trail() -> void:
	if _trail == null:
		return

	var p_enabled: bool = _p_bool("tail_enabled", true)
	_trail.visible = trail_enabled and p_enabled
	if not _trail.visible:
		return

	var m: Mesh = _p_mesh("tail_mesh")
	if m != null:
		_trail.mesh = m
	_trail.scale = Vector3.ONE * _p_float("tail_scale", 0.9)
	_trail.position = _p_vec3("tail_offset", Vector3(-1.4, 0.0, 0.0))

	_mat_energy_trail = _make_energy_material(_col_trail, _p_float("tail_alpha", 0.35), _p_float("tail_emission_strength", 1.35))
	_trail.material_override = _mat_energy_trail

func _apply_rings() -> void:
	if _rings == null:
		return

	_rings.visible = rings_enabled and _p_bool("rings_enabled", true)
	if not _rings.visible:
		return

	# Ensure quad mesh and keep its size synced
	var q: QuadMesh = _rings.mesh as QuadMesh
	if q == null:
		q = QuadMesh.new()
		_rings.mesh = q
	q.size = Vector2.ONE * _p_float("rings_quad_size", rings_quad_size)

	# Cache base scale (used by breathing in _process)
	_rings_scale_base = _p_float("rings_scale", 0.55)

	_mat_rings = _make_rings_material(_col_rings)
	_rings.material_override = _mat_rings

func _apply_sparks() -> void:
	if _sparks == null:
		return

	var p_enabled: bool = _p_bool("sparks_enabled", true)
	_sparks.visible = sparks_enabled and p_enabled
	if not _sparks.visible:
		_sparks.emitting = false
		return

	# Ensure process material is ParticleProcessMaterial
	var pm: ParticleProcessMaterial = _sparks.process_material as ParticleProcessMaterial
	if pm == null:
		pm = ParticleProcessMaterial.new()
		_sparks.process_material = pm

	# Spawn from a ring around the head
	_set_prop(pm, "emission_shape", int(ParticleProcessMaterial.EMISSION_SHAPE_RING))
	_set_prop(pm, "emission_ring_radius", _p_float("sparks_orbit_radius", 0.22))
	_set_prop(pm, "emission_ring_inner_radius", 0.0)
	_set_prop(pm, "emission_ring_axis", Vector3.FORWARD)

	# Rates / lifetime
	var lifetime: float = _p_float("sparks_lifetime", 0.75)
	_sparks.lifetime = lifetime
	_sparks.one_shot = false
	_sparks.emitting = true

	var rate: float = _p_float("sparks_rate", 180.0)
	var amount_i: int = maxi(24, int(rate * lifetime))
	_sparks.amount = amount_i

	_set_prop(pm, "lifetime_randomness", _p_float("sparks_lifetime_randomness", 0.35))
	_set_prop(pm, "explosiveness", _p_float("sparks_explosiveness", 0.15))

	# Direction / spread / speed
	_set_prop(pm, "direction", Vector3.BACK)
	_set_prop(pm, "spread", _p_float("sparks_direction_spread", 14.0))
	_set_prop(pm, "initial_velocity_min", _p_float("sparks_initial_velocity_min", 0.0))
	_set_prop(pm, "initial_velocity_max", _p_float("sparks_initial_velocity_max", 0.0))

	# Orbit + angular
	var orbit_speed: float = _p_float("sparks_orbit_speed", 3.0)
	_set_prop(pm, "orbit_velocity", Vector2(orbit_speed * 0.9, orbit_speed * 1.1))
	_set_prop(pm, "angular_velocity_min", -6.0)
	_set_prop(pm, "angular_velocity_max", 6.0)

	# Size
	_set_prop(pm, "scale_min", _p_float("sparks_size_min", 0.05))
	_set_prop(pm, "scale_max", _p_float("sparks_size_max", 0.10))

	# Color (and optional full-spectrum ramp)
	_set_prop(pm, "color", _col_sparks)
	var use_full: bool = _p_bool("sparks_use_full_spectrum_step_palette", false)
	if use_full:
		var gfull: GradientTexture1D = _build_step_gradient(_palette_full_spectrum(), 12)
		_set_prop(pm, "color_ramp", gfull)
	else:
		var g: GradientTexture1D = _build_step_gradient(
			_palette_for_scheme(_scheme_sparks, _col_core, _mix_seed(_seed_value, _SALT_SPARKS)),
			6
		)
		_set_prop(pm, "color_ramp", g)

	# Draw pass mesh/material (billboard + emission)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE * _p_float("sparks_quad_size", 0.06)
	_set_prop(_sparks, "draw_pass_1", quad)

	var sm: StandardMaterial3D = StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.albedo_color = _col_sparks
	sm.emission_enabled = true
	sm.emission = _col_sparks
	sm.emission_energy_multiplier = _p_float("sparks_emission_strength", 2.0)
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_set_prop(_sparks, "draw_pass_1_material", sm)

	# Built-in particle trails (if supported by this build)
	_set_prop(_sparks, "trail_enabled", true)
	_set_prop(_sparks, "trail_lifetime", _p_float("sparks_trail_lifetime", 0.25))
	_set_prop(_sparks, "trail_sections", _p_int("sparks_trail_sections", 6))

# -----------------------------
# Color assignment
# -----------------------------
func _assign_scheme_colors() -> void:
	if not use_color_schemes or not _p_bool("use_color_schemes", true):
		_assign_random_colors()
		return

	# Core is the anchor (full spectrum via hue bin + weights)
	var rng_core: RandomNumberGenerator = RandomNumberGenerator.new()
	rng_core.seed = _mix_seed(_seed_value, _SALT_CORE)

	var base_bin: int = _pick_weighted_index_12(rng_core, _p_weights_12("spectrum_bin_weights"))
	var h_core: float = (float(base_bin) + rng_core.randf()) / 12.0
	var sat_min: float = _p_float("sat_min", 0.70)
	var sat_max: float = _p_float("sat_max", 1.00)
	var val_min: float = _p_float("val_min", 0.70)
	var val_max: float = _p_float("val_max", 1.60)

	var s_core: float = rng_core.randf_range(sat_min, sat_max)
	var v_core: float = rng_core.randf_range(val_min, val_max)
	_col_core = Color.from_hsv(_wrap01(h_core), clampf(s_core, 0.0, 1.0), maxf(0.0, v_core), 1.0)

	# Pool to prevent duplicates (optional)
	var pool: Array[int] = _ALL_SCHEMES.duplicate()
	_reserve_override(head_scheme_override, pool)
	_reserve_override(trail_scheme_override, pool)
	_reserve_override(rings_scheme_override, pool)
	_reserve_override(sparks_scheme_override, pool)

	# Global scheme from preset (0=Random, 1..6=schemes)
	var preset_scheme_raw: int = _p_int("color_scheme", 0)
	var preset_scheme: int = _preset_scheme_to_internal(preset_scheme_raw)

	var global_scheme: int = preset_scheme
	if global_scheme < 0:
		var rng_g: RandomNumberGenerator = RandomNumberGenerator.new()
		rng_g.seed = _mix_seed(_seed_value, _SALT_SCHEME)
		global_scheme = rng_g.randi_range(0, 5)

	# Resolve per-component schemes deterministically
	_scheme_head = _resolve_component_scheme(head_scheme_override, global_scheme, pool, _SALT_HEAD)
	_scheme_trail = _resolve_component_scheme(trail_scheme_override, global_scheme, pool, _SALT_TRAIL)
	_scheme_rings = _resolve_component_scheme(rings_scheme_override, global_scheme, pool, _SALT_RINGS)
	_scheme_sparks = _resolve_component_scheme(sparks_scheme_override, global_scheme, pool, _SALT_SPARKS)

	# Colors from each component palette (anchored to core hue)
	_col_head = _pick_from_palette(_palette_for_scheme(_scheme_head, _col_core, _mix_seed(_seed_value, _SALT_HEAD)), _mix_seed(_seed_value, _SALT_HEAD ^ 0x1))
	_col_trail = _pick_from_palette(_palette_for_scheme(_scheme_trail, _col_core, _mix_seed(_seed_value, _SALT_TRAIL)), _mix_seed(_seed_value, _SALT_TRAIL ^ 0x1))
	_col_rings = _pick_from_palette(_palette_for_scheme(_scheme_rings, _col_core, _mix_seed(_seed_value, _SALT_RINGS)), _mix_seed(_seed_value, _SALT_RINGS ^ 0x1))
	_col_sparks = _pick_from_palette(_palette_for_scheme(_scheme_sparks, _col_core, _mix_seed(_seed_value, _SALT_SPARKS)), _mix_seed(_seed_value, _SALT_SPARKS ^ 0x1))

func _assign_random_colors() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _mix_seed(_seed_value, 0x1234567)

	_col_core = Color.from_hsv(rng.randf(), 1.0, 1.0, 1.0)
	_col_head = Color.from_hsv(rng.randf(), 1.0, 1.0, 1.0)
	_col_trail = Color.from_hsv(rng.randf(), 1.0, 1.0, 1.0)
	_col_rings = Color.from_hsv(rng.randf(), 1.0, 1.0, 1.0)
	_col_sparks = Color.from_hsv(rng.randf(), 1.0, 1.0, 1.0)

func _preset_scheme_to_internal(preset_val: int) -> int:
	# Preset: 0=Random, 1..6 = Mono..Tetradic
	if preset_val <= 0:
		return -1
	return clampi(preset_val - 1, 0, 5)

func _reserve_override(override_val: int, pool: Array[int]) -> void:
	if allow_duplicate_component_schemes:
		return
	if override_val < 0:
		return
	var v: int = clampi(override_val, 0, 5)
	var idx: int = pool.find(v)
	if idx != -1:
		pool.remove_at(idx)

func _pick_scheme_from_pool(pool: Array[int], seed_i: int) -> int:
	if pool.is_empty():
		# fallback: allow reuse if pool exhausted
		return int(ColorScheme.ANALOGOUS)
	var r: RandomNumberGenerator = RandomNumberGenerator.new()
	r.seed = seed_i
	return pool[r.randi_range(0, pool.size() - 1)]

func _resolve_component_scheme(override_val: int, global_scheme: int, pool: Array[int], salt: int) -> int:
	if override_val >= 0:
		return clampi(override_val, 0, 5)

	if not separate_component_schemes:
		return clampi(global_scheme, 0, 5)

	var chosen: int = _pick_scheme_from_pool(pool, _mix_seed(_seed_value, salt ^ _SALT_SCHEME))
	if not allow_duplicate_component_schemes:
		pool.erase(chosen)
	return chosen

func _palette_for_scheme(scheme_i: int, core_col: Color, sub_seed: int) -> Array[Color]:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = sub_seed

	var h: float = core_col.h
	var s0: float = clampf(core_col.s, 0.0, 1.0)
	var v0: float = maxf(0.0, core_col.v)

	var sat_min: float = _p_float("sat_min", 0.70)
	var sat_max: float = _p_float("sat_max", 1.00)
	var val_min: float = _p_float("val_min", 0.70)
	var val_max: float = _p_float("val_max", 1.60)

	# derive base s/v around core
	var s: float = clampf(rng.randf_range(sat_min, sat_max), 0.0, 1.0)
	var v: float = maxf(0.0, rng.randf_range(val_min, val_max))

	var bins: Array[int] = _scheme_bins(scheme_i, int(floor(h * 12.0)) % 12)

	var out: Array[Color] = []
	for b: int in bins:
		var hh: float = (float(b) + rng.randf() * 0.15) / 12.0
		out.append(Color.from_hsv(_wrap01(hh), s, v, 1.0))
		# also add a brighter companion to give choices
		out.append(Color.from_hsv(_wrap01(hh), clampf(s * 0.85, 0.0, 1.0), maxf(0.0, v * 1.15), 1.0))
	return out

func _scheme_bins(scheme_i: int, base_bin: int) -> Array[int]:
	var bins: Array[int] = []
	var b: int = ((base_bin % 12) + 12) % 12

	match scheme_i:
		ColorScheme.MONOCHROMATIC:
			bins = [b]
		ColorScheme.ANALOGOUS:
			bins = [((b - 1 + 12) % 12), b, ((b + 1) % 12)]
		ColorScheme.COMPLEMENTARY:
			bins = [b, ((b + 6) % 12)]
		ColorScheme.TRIAD:
			bins = [b, ((b + 4) % 12), ((b + 8) % 12)]
		ColorScheme.SPLIT_COMPLEMENTARY:
			bins = [b, ((b + 5) % 12), ((b + 7) % 12)]
		ColorScheme.TETRADIC:
			bins = [b, ((b + 3) % 12), ((b + 6) % 12), ((b + 9) % 12)]
		_:
			bins = [b]
	return bins

func _pick_from_palette(pal: Array[Color], sub_seed: int) -> Color:
	if pal.is_empty():
		return Color.WHITE
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = sub_seed
	var idx: int = rng.randi_range(0, pal.size() - 1)
	return pal[idx]

func _palette_full_spectrum() -> Array[Color]:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _mix_seed(_seed_value, 0xF00DF00D)

	var sat_min: float = _p_float("sat_min", 0.70)
	var sat_max: float = _p_float("sat_max", 1.00)
	var val_min: float = _p_float("val_min", 0.70)
	var val_max: float = _p_float("val_max", 1.60)

	var s: float = clampf(rng.randf_range(sat_min, sat_max), 0.0, 1.0)
	var v: float = maxf(0.0, rng.randf_range(val_min, val_max))

	var out: Array[Color] = []
	var i: int = 0
	while i < 12:
		var h: float = float(i) / 12.0
		out.append(Color.from_hsv(h, s, v, 1.0))
		i += 1
	return out

# -----------------------------
# Materials / shaders
# -----------------------------
func _make_energy_material(col: Color, alpha: float, emission_mul: float) -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _energy_shader()
	mat.set_shader_parameter("albedo_color", Color(col.r, col.g, col.b, clampf(alpha, 0.0, 1.0)))
	mat.set_shader_parameter("emission_color", col)
	mat.set_shader_parameter("emission_mul", emission_mul)
	mat.set_shader_parameter("noise_tex", _noise_tex)
	mat.set_shader_parameter("uv_scale", _p_float("uv_scale", 1.0))
	mat.set_shader_parameter("scroll_speed", _p_float("scroll_speed", 0.35))
	mat.set_shader_parameter("time_offset", float(_seed_value % 1000) * 0.001)
	return mat

func _make_rings_material(col: Color) -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _rings_shader()
	mat.set_shader_parameter("ring_color", col)
	mat.set_shader_parameter("emission_mul", _p_float("rings_emission_strength", 2.0))
	mat.set_shader_parameter("count", _p_int("rings_count", 4))
	mat.set_shader_parameter("thickness", _p_float("rings_thickness", 0.06))
	mat.set_shader_parameter("softness", _p_float("rings_softness", 0.06))
	mat.set_shader_parameter("pulse_speed", rings_breath_speed)
	mat.set_shader_parameter("pulse_base", rings_pulse_base)
	mat.set_shader_parameter("pulse_amp", rings_pulse_amp)
	mat.set_shader_parameter("min_radius", rings_min_radius)
	mat.set_shader_parameter("max_radius", rings_max_radius)
	var p_rings_tex: Texture2D = _p_tex("rings_texture")
	var use_rings_tex: Texture2D = p_rings_tex if p_rings_tex != null else rings_texture
	mat.set_shader_parameter("rings_tex", use_rings_tex if use_rings_tex != null else _white_texture())
	mat.set_shader_parameter("rings_tex_uv_scale", rings_tex_uv_scale)
	mat.set_shader_parameter("rings_tex_scroll", rings_tex_scroll)
	mat.set_shader_parameter("rings_tex_rotate_speed", rings_tex_rotate_speed)
	mat.set_shader_parameter("rings_tex_strength", rings_tex_strength)
	mat.set_shader_parameter("time_offset", float((_seed_value ^ 0x55AA) % 1000) * 0.001)
	return mat

func _energy_shader() -> Shader:
	var sh: Shader = Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D noise_tex;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 emission_color : source_color = vec3(1.0);
uniform float emission_mul = 1.0;
uniform float uv_scale = 1.0;
uniform float scroll_speed = 0.35;
uniform float time_offset = 0.0;

void fragment() {
	vec2 uv = UV * uv_scale;
	float t = TIME * scroll_speed + time_offset;
	vec2 suv = uv + vec2(t, -t * 0.73);

	float n = texture(noise_tex, suv).r;
	// Soft "rolling" density
	float d = smoothstep(0.15, 0.85, n);

	ALBEDO = albedo_color.rgb;
	ALPHA  = albedo_color.a * (0.25 + 0.75 * d);

	EMISSION = emission_color * emission_mul * (0.35 + 0.65 * d);
}
"""
	return sh

func _rings_shader() -> Shader:
	var sh: Shader = Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform vec3 ring_color : source_color = vec3(1.0);
uniform float emission_mul = 2.0;
uniform int count = 4;
uniform float thickness = 0.06;
uniform float softness = 0.06;
uniform float pulse_speed = 1.2;
uniform float pulse_base = 0.85;
uniform float pulse_amp = 0.25;
uniform float min_radius = 0.60;
uniform float max_radius = 0.92;
uniform sampler2D rings_tex;
uniform vec2 rings_tex_uv_scale = vec2(1.0, 1.0);
uniform vec2 rings_tex_scroll = vec2(0.10, -0.08);
uniform float rings_tex_rotate_speed = 0.0;
uniform float rings_tex_strength = 0.0;
uniform float time_offset = 0.0;

float ring_mask(float r, float center_r, float thick, float soft) {
	float d = abs(r - center_r);
	float a = 1.0 - smoothstep(thick, thick + soft, d);
	return clamp(a, 0.0, 1.0);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);

	float t = TIME * pulse_speed + time_offset;
	float pulse = pulse_base + pulse_amp * sin(t * 6.28318);

	float a = 0.0;

	// Concentric rings (centers spread across [min_radius..max_radius])
	float c = float(max(count, 1));
	float rr_min = clamp(min(min_radius, max_radius), 0.0, 1.2);
	float rr_max = clamp(max(min_radius, max_radius), 0.0, 1.2);
	for (int i = 0; i < 32; i++) {
		if (i >= count) break;
		float fi = float(i);
		float rr = mix(rr_min, rr_max, (fi + 0.5) / c);
		a = max(a, ring_mask(r, rr, thickness, softness));
	}

	float ang = atan(p.y, p.x) + TIME * rings_tex_rotate_speed;
	mat2 rot = mat2(cos(ang), -sin(ang), sin(ang), cos(ang));
	vec2 tuv = (rot * (UV - vec2(0.5))) + vec2(0.5);
	tuv = tuv * rings_tex_uv_scale + TIME * rings_tex_scroll;
	float tex_v = texture(rings_tex, tuv).r;
	float tex_mul = mix(1.0, tex_v, clamp(rings_tex_strength, 0.0, 1.0));
	a *= tex_mul;

	// Fade out outside the last ring
	float fade = 1.0 - smoothstep(1.0, 1.05, r);

	ALBEDO = ring_color;
	ALPHA = a * fade * max(0.0, pulse);
	EMISSION = ring_color * emission_mul * ALPHA;
}
"""
	return sh

# -----------------------------
# Noise texture
# -----------------------------
func _build_noise_texture() -> Texture2D:
	var nt: NoiseTexture2D = NoiseTexture2D.new()
	var fn: FastNoiseLite = FastNoiseLite.new()

	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	fn.frequency = _p_float("noise_frequency", 2.0)
	fn.fractal_octaves = 3
	fn.fractal_lacunarity = 2.0
	fn.fractal_gain = 0.5

	nt.noise = fn

	var size_i: int = _p_int("noise_size", 256)
	nt.width = size_i
	nt.height = size_i

	# Seamless if available
	_set_prop(nt, "seamless", true)

	return nt

# -----------------------------
# Gradient helper for particle ramps
# -----------------------------
func _build_step_gradient(colors: Array[Color], steps: int) -> GradientTexture1D:
	var gtex: GradientTexture1D = GradientTexture1D.new()
	var grad: Gradient = Gradient.new()

	var n: int = maxi(1, steps)
	var eps: float = 0.0005

	var i: int = 0
	while i < n:
		var c: Color = colors[i % colors.size()]
		var t0: float = float(i) / float(n)
		var t1: float = float(i + 1) / float(n)

		grad.add_point(clampf(t0 + eps, 0.0, 1.0), c)
		grad.add_point(clampf(t1 - eps, 0.0, 1.0), c)
		i += 1

	gtex.gradient = grad
	return gtex

# -----------------------------
# Node creation / lookup
# -----------------------------
func _ensure_nodes() -> void:
	_head = get_node_or_null("Head") as MeshInstance3D
	if _head == null:
		_head = MeshInstance3D.new()
		_head.name = "Head"
		add_child(_head)

	_trail = get_node_or_null("Trail") as MeshInstance3D
	if _trail == null:
		_trail = MeshInstance3D.new()
		_trail.name = "Trail"
		add_child(_trail)

	_sparks = get_node_or_null("Sparks") as GPUParticles3D
	if _sparks == null:
		_sparks = GPUParticles3D.new()
		_sparks.name = "Sparks"
		add_child(_sparks)

	_core = get_node_or_null("Core") as MeshInstance3D
	if _core == null:
		_core = MeshInstance3D.new()
		_core.name = "Core"
		add_child(_core)

	_core_inner = get_node_or_null("CoreInner") as MeshInstance3D
	if _core_inner == null:
		_core_inner = MeshInstance3D.new()
		_core_inner.name = "CoreInner"
		_core.add_child(_core_inner)

	_rings = get_node_or_null("Rings") as MeshInstance3D
	if _rings == null:
		_rings = MeshInstance3D.new()
		_rings.name = "Rings"
		add_child(_rings)

	# Default placement: keep everything aligned
	_core.position = Vector3.ZERO
	if _head != null:
		_head.position = Vector3.ZERO
	if _trail != null:
		# tail offset handled in _apply_trail()
		pass
	if _sparks != null:
		_sparks.position = Vector3.ZERO
	if _rings != null:
		_rings.position = Vector3.ZERO

func _find_camera() -> Camera3D:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null:
		return cam

	# fallback: a Camera3D node named "Camera3D" under this projectile
	var n: Node = find_child("Camera3D", true, false)
	if n != null and n is Camera3D:
		return n as Camera3D

	return null

# -----------------------------
# Preset getters (safe)
# -----------------------------
func _p_bool(key: String, default_val: bool) -> bool:
	if preset == null:
		return default_val
	var v = preset.get(key)
	if v == null:
		return default_val
	return bool(v)

func _p_int(key: String, default_val: int) -> int:
	if preset == null:
		return default_val
	var v = preset.get(key)
	if v == null:
		return default_val
	if typeof(v) == TYPE_INT:
		return int(v)
	if typeof(v) == TYPE_FLOAT:
		return int(round(float(v)))
	return default_val

func _p_float(key: String, default_val: float) -> float:
	if preset == null:
		return default_val
	var v = preset.get(key)
	if v == null:
		return default_val
	if typeof(v) == TYPE_FLOAT:
		return float(v)
	if typeof(v) == TYPE_INT:
		return float(int(v))
	return default_val

func _p_vec3(key: String, default_val: Vector3) -> Vector3:
	if preset == null:
		return default_val
	var v = preset.get(key)
	if v == null:
		return default_val
	if v is Vector3:
		return v
	return default_val

func _p_mesh(key: String) -> Mesh:
	if preset == null:
		return null
	var v = preset.get(key)
	return v as Mesh

func _p_weights_12(key: String) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if preset == null:
		return out
	var v = preset.get(key)
	if v == null:
		return out
	if v is PackedFloat32Array:
		out = v
	return out

func _p_tex(key: String) -> Texture2D:
	if preset == null:
		return null
	var v = preset.get(key)
	return v as Texture2D

# -----------------------------
# Small helpers
# -----------------------------
func _wrap01(x: float) -> float:
	var y: float = fposmod(x, 1.0)
	return y

func _brighten(c: Color, mul: float) -> Color:
	return Color(c.r * mul, c.g * mul, c.b * mul, c.a)

func _pick_weighted_index_12(rng: RandomNumberGenerator, weights: PackedFloat32Array) -> int:
	if weights.size() != 12:
		return rng.randi_range(0, 11)

	var total: float = 0.0
	var i: int = 0
	while i < 12:
		total += maxf(0.0, float(weights[i]))
		i += 1
	if total <= 0.000001:
		return rng.randi_range(0, 11)

	var r: float = rng.randf() * total
	var acc: float = 0.0
	i = 0
	while i < 12:
		acc += maxf(0.0, float(weights[i]))
		if r <= acc:
			return i
		i += 1
	return 11

# Deterministic 32-bit seed mixer (no huge 64-bit hex constants)
func _mix_seed(a: int, b: int) -> int:
	var x: int = int((a ^ b) & 0xFFFFFFFF)
	x ^= (x >> 16)
	x = int((x * 0x85EBCA6B) & 0xFFFFFFFF)
	x ^= (x >> 13)
	x = int((x * 0xC2B2AE35) & 0xFFFFFFFF)
	x ^= (x >> 16)
	# keep positive
	return int(x & 0x7FFFFFFF)

func _set_prop(obj: Object, prop: String, value) -> void:
	if obj == null:
		return
	if _has_prop(obj, prop):
		obj.set(prop, value)

func _white_texture() -> Texture2D:
	if _white_tex != null:
		return _white_tex
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1, 1, 1, 1))
	_white_tex = ImageTexture.create_from_image(img)
	return _white_tex

func _has_prop(obj: Object, prop: String) -> bool:
	var plist: Array[Dictionary] = obj.get_property_list()
	for d: Dictionary in plist:
		if d.has("name"):
			var n: String = String(d["name"])
			if n == prop:
				return true
	return false
