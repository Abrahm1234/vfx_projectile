@tool
extends Node3D
class_name VFXProjectile

# -----------------------------------------------------------------------------
# Scene requirements (children)
#   - Head   : MeshInstance3D
#   - Trail  : MeshInstance3D
#   - Sparks : GPUParticles3D
# This script will also create:
#   - _core      : MeshInstance3D (inside Head)
#   - _rings_root: Node3D (+ one QuadMesh ring surface)
#   - _trail_glow: MeshInstance3D (optional duplicate of Trail for extra glow)
# -----------------------------------------------------------------------------

# ---------------------------- Preview / apply -------------------------------

@export_group("Preview")
@export var auto_preview_in_editor: bool = true
@export var preview_seed: int = 12368
@export var auto_apply_on_ready: bool = true

# Your preset resource (any Resource). If it has matching exported vars, they’ll be read.
@export_group("Preset")
@export var preset: Resource

# ----------------------------- Core / Rings ---------------------------------

@export_group("Core")
@export var core_enabled: bool = true
@export var core_mesh: Mesh
@export_range(0.05, 1.0, 0.01) var core_scale: float = 0.45

@export_group("Rings")
@export var rings_enabled: bool = true
@export var rings_anchor_to_head_mesh: bool = true
@export var rings_face_camera: bool = true
@export var rings_local_offset: Vector3 = Vector3.ZERO
@export_range(0.2, 4.0, 0.01) var rings_scale: float = 1.35
@export_range(1, 12, 1) var rings_count: int = 4
@export_range(0.005, 0.5, 0.001) var rings_thickness: float = 0.06
@export_range(0.0, 0.5, 0.001) var rings_softness: float = 0.06
@export_range(0.0, 8.0, 0.01) var rings_spin_speed: float = 1.0

# ----------------------------- Trail glow -----------------------------------

@export_group("Trail Glow")
@export var trail_glow_enabled: bool = true
@export var trail_glow_follow_trail: bool = true
@export_range(0.0, 3.0, 0.01) var trail_glow_boost: float = 0.8

# ---------------------------- Color schemes ---------------------------------

enum ColorScheme {
	RANDOM = 0,
	MONOCHROMATIC = 1,
	ANALOGOUS = 2,
	COMPLEMENTARY = 3,
	TRIAD = 4,
	SPLIT_COMPLEMENTARY = 5,
	TETRADIC = 6,
}

@export_group("Color Schemes")
@export var use_color_schemes: bool = true

# If false, everything uses `color_scheme` (single scheme).
@export var schemes_per_component: bool = true

# If true and auto-assigning, Head/Trail/Rings/Sparks will be unique schemes (when possible).
@export var enforce_unique_component_schemes: bool = true

@export_enum("Random","Monochromatic","Analogous","Complementary","Triad","Split-Complementary","Tetradic")
var color_scheme: int = ColorScheme.RANDOM

# Per-component overrides (0 = auto / random)
@export_enum("Auto","Monochromatic","Analogous","Complementary","Triad","Split-Complementary","Tetradic")
var head_scheme: int = 0
@export_enum("Auto","Monochromatic","Analogous","Complementary","Triad","Split-Complementary","Tetradic")
var trail_scheme: int = 0
@export_enum("Auto","Monochromatic","Analogous","Complementary","Triad","Split-Complementary","Tetradic")
var rings_scheme: int = 0
@export_enum("Auto","Monochromatic","Analogous","Complementary","Triad","Split-Complementary","Tetradic")
var sparks_scheme: int = 0

# Hue selection: 12 bins across the spectrum. If size != 12, uniform weights are used.
@export var spectrum_bin_weights: PackedFloat32Array = PackedFloat32Array()

# Saturation / value ranges (if your preset has sat_min/sat_max/val_min/val_max, those override these)
@export_range(0.0, 1.0, 0.01) var sat_min: float = 0.55
@export_range(0.0, 1.0, 0.01) var sat_max: float = 1.00
@export_range(0.0, 4.0, 0.01) var val_min: float = 0.70
@export_range(0.0, 4.0, 0.01) var val_max: float = 1.60

# Sparks palette behavior
@export var sparks_use_full_spectrum_steps: bool = true
@export_range(2, 24, 1) var sparks_step_count: int = 12

# Particle trails (per particle) on the Sparks node (if supported by your Godot build)
@export_group("Sparks Trails")
@export var sparks_trails_enabled: bool = true
@export_range(0.01, 2.0, 0.01) var sparks_trail_lifetime: float = 0.25
@export_range(2, 16, 1) var sparks_trail_sections: int = 6

# ------------------------------ Internals -----------------------------------

@onready var _head: MeshInstance3D = get_node_or_null("Head") as MeshInstance3D
@onready var _trail: MeshInstance3D = get_node_or_null("Trail") as MeshInstance3D
@onready var _sparks: GPUParticles3D = get_node_or_null("Sparks") as GPUParticles3D

var _seed_value: int = 0

var _core: MeshInstance3D
var _rings_root: Node3D
var _rings_mesh: MeshInstance3D
var _trail_glow: MeshInstance3D

var _noise_tex: Texture2D
var _sparks_ramp_tex: GradientTexture1D

var _col_core: Color = Color(1, 1, 1, 1)
var _col_head_base: Color = Color(1, 1, 1, 1)
var _col_head_core: Color = Color(1, 1, 1, 1)
var _col_trail_base: Color = Color(1, 1, 1, 1)
var _col_trail_core: Color = Color(1, 1, 1, 1)
var _col_rings: Color = Color(1, 1, 1, 1)
var _col_sparks: Color = Color(1, 1, 1, 1)

# Deterministic, per-component seed salts (VALID hex only)
const _SEED_CORE: int = 0xC0DEF00D
const _SEED_SCHEMES: int = 0x5C4E9A11
const _SEED_HEAD: int = 0x11EA12ED
const _SEED_TRAIL: int = 0x7A11F00D
const _SEED_RINGS: int = 0xA91C3E57
const _SEED_SPARKS: int = 0x5A92BEEF

# ------------------------------- Lifecycle ----------------------------------

func _ready() -> void:
	if _head == null or _trail == null or _sparks == null:
		push_error("VFXProjectile: Missing required children (Head, Trail, Sparks).")
		return

	_ensure_extra_nodes()

	if Engine.is_editor_hint():
		if auto_preview_in_editor:
			apply_seed(preview_seed)
			if auto_apply_on_ready:
				apply_preset(preset)
	else:
		if auto_apply_on_ready:
			apply_seed(preview_seed)
			apply_preset(preset)

func _process(delta: float) -> void:
	if _rings_root != null and rings_enabled:
		if rings_spin_speed != 0.0:
			_rings_root.rotate_object_local(Vector3.FORWARD, rings_spin_speed * delta)

		if rings_face_camera:
			var cam: Camera3D = _get_camera()
			if cam != null:
				_face_camera(_rings_root, cam)

	if _trail_glow != null and trail_glow_enabled and trail_glow_follow_trail:
		_trail_glow.global_transform = _trail.global_transform

# ------------------------------ Public API ----------------------------------

func apply_seed(seed_value: int) -> void:
	_seed_value = seed_value

func apply_preset(p: Resource) -> void:
	preset = p
	if _head == null:
		return

	# Build noise texture (if preset provides noise_size/noise_frequency, use it)
	var n_size: int = _p_int("noise_size", 256)
	var n_freq: float = _p_float("noise_frequency", 2.25)
	_noise_tex = _build_noise_texture(n_size, n_freq, _mix_seed(_seed_value, 0xC0FFEE))

	_assign_scheme_colors()
	_apply_all()

# ------------------------------- Apply all ----------------------------------

func _apply_all() -> void:
	_apply_head()
	_apply_core()
	_apply_trail()
	_apply_rings()
	_apply_sparks()

# -------------------------------- Head --------------------------------------

func _apply_head() -> void:
	if _head == null:
		return

	# Allow preset to drive strength/scale (fallbacks are safe)
	var distort: float = _p_float("head_distort_strength", 0.25)
	var glow: float = _p_float("head_glow_strength", 2.25)
	var radius_scale: float = _p_float("head_radius_scale", 1.0)

	_head.scale = Vector3.ONE * radius_scale

	var mat := ShaderMaterial.new()
	mat.shader = _shader_head()
	mat.set_shader_parameter("noise_tex", _noise_tex)
	mat.set_shader_parameter("base_color", _col_head_base)
	mat.set_shader_parameter("core_color", _col_head_core)
	mat.set_shader_parameter("distort_strength", distort)
	mat.set_shader_parameter("glow_strength", glow)
	_head.material_override = mat

# -------------------------------- Core --------------------------------------

func _apply_core() -> void:
	if _core == null:
		return

	_core.visible = core_enabled
	if not core_enabled:
		return

	if core_mesh != null:
		_core.mesh = core_mesh
	elif _core.mesh == null:
		var sm := SphereMesh.new()
		sm.radial_segments = 24
		sm.rings = 16
		_core.mesh = sm

	_core.scale = Vector3.ONE * core_scale

	var mat := ShaderMaterial.new()
	mat.shader = _shader_core()
	mat.set_shader_parameter("noise_tex", _noise_tex)
	mat.set_shader_parameter("core_color", _col_core)
	mat.set_shader_parameter("glow_strength", _p_float("head_glow_strength", 2.25) * 1.15)
	_core.material_override = mat

# -------------------------------- Trail -------------------------------------

func _apply_trail() -> void:
	if _trail == null:
		return

	var distort: float = _p_float("trail_distort_strength", 0.18)
	var glow: float = _p_float("trail_glow_strength", 1.8)
	var radius_scale: float = _p_float("trail_radius_scale", 1.0)

	_trail.scale = Vector3.ONE * radius_scale

	var mat := ShaderMaterial.new()
	mat.shader = _shader_trail()
	mat.set_shader_parameter("noise_tex", _noise_tex)
	mat.set_shader_parameter("base_color", _col_trail_base)
	mat.set_shader_parameter("core_color", _col_trail_core)
	mat.set_shader_parameter("distort_strength", distort)
	mat.set_shader_parameter("glow_strength", glow)
	_trail.material_override = mat

	if _trail_glow != null:
		_trail_glow.visible = trail_glow_enabled
		if trail_glow_enabled:
			var glow_mat := ShaderMaterial.new()
			glow_mat.shader = _shader_trail()
			glow_mat.set_shader_parameter("noise_tex", _noise_tex)
			glow_mat.set_shader_parameter("base_color", _brighten(_col_trail_base, 1.0 + trail_glow_boost))
			glow_mat.set_shader_parameter("core_color", _brighten(_col_trail_core, 1.0 + trail_glow_boost))
			glow_mat.set_shader_parameter("distort_strength", distort * 0.65)
			glow_mat.set_shader_parameter("glow_strength", glow * (1.0 + trail_glow_boost))
			_trail_glow.material_override = glow_mat

# -------------------------------- Rings -------------------------------------

func _apply_rings() -> void:
	if _rings_root == null or _rings_mesh == null:
		return

	_rings_root.visible = rings_enabled
	if not rings_enabled:
		return

	_sync_rings_to_head_center()
	_rings_root.scale = Vector3.ONE * rings_scale

	var mat := ShaderMaterial.new()
	mat.shader = _shader_rings()
	mat.set_shader_parameter("ring_color", _col_rings)
	mat.set_shader_parameter("ring_count", rings_count)
	mat.set_shader_parameter("thickness", rings_thickness)
	mat.set_shader_parameter("softness", rings_softness)
	_rings_mesh.material_override = mat

# -------------------------------- Sparks ------------------------------------

func _apply_sparks() -> void:
	if _sparks == null:
		return

	# Ensure ParticleProcessMaterial for simulation
	var pm: ParticleProcessMaterial = _sparks.process_material as ParticleProcessMaterial
	if pm == null:
		pm = ParticleProcessMaterial.new()
		_sparks.process_material = pm

	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_radius = _p_float("sparks_orbit_radius", 0.22)
	pm.emission_ring_inner_radius = 0.0
	pm.emission_ring_axis = Vector3.FORWARD

	_sparks.amount = _p_int("sparks_amount", 140)
	_sparks.lifetime = _p_float("sparks_lifetime", 0.75)
	_sparks.explosiveness = _p_float("sparks_explosiveness", 0.15)
	pm.direction = Vector3.BACK
	pm.spread = _p_float("sparks_direction_spread", 14.0)
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0

	# Orbit around axis using orbit_velocity (Vector2(min,max))
	var orbit_speed: float = _p_float("sparks_orbit_speed", 3.0)
	pm.orbit_velocity = Vector2(orbit_speed * 0.9, orbit_speed * 1.1)

	pm.scale_min = _p_float("sparks_scale", 0.06) * 0.75
	pm.scale_max = _p_float("sparks_scale", 0.06) * 1.10

	# Color ramp (step / threshold look)
	if _sparks_ramp_tex != null:
		pm.color_ramp = _sparks_ramp_tex

	# Particle trails (if your Godot build exposes these properties on GPUParticles3D)
	_set_prop_if_exists(_sparks, "trail_enabled", sparks_trails_enabled)
	_set_prop_if_exists(_sparks, "trail_lifetime", sparks_trail_lifetime)
	_set_prop_if_exists(_sparks, "trail_sections", sparks_trail_sections)

	# Draw pass mesh (a quad)
	if _sparks.draw_pass_1 == null:
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		_sparks.draw_pass_1 = quad

	# Render material (additive sprite)
	var render_mat := ShaderMaterial.new()
	render_mat.shader = _shader_sparks_draw()
	render_mat.set_shader_parameter("tint", _col_sparks)
	_sparks.material_override = render_mat

# ----------------------------- Color assignment -----------------------------

func _assign_scheme_colors() -> void:
	# sat/val may come from preset if present
	var s_min: float = _p_float("sat_min", sat_min)
	var s_max: float = _p_float("sat_max", sat_max)
	var v_min: float = _p_float("val_min", val_min)
	var v_max: float = _p_float("val_max", val_max)

	var rng_sv := RandomNumberGenerator.new()
	rng_sv.seed = _mix_seed(_seed_value, 0xC0FFEE)
	var s: float = rng_sv.randf_range(s_min, s_max)
	var v: float = rng_sv.randf_range(v_min, v_max)

	# --- CORE is the anchor: pick a weighted spectrum bin, then randomize within the bin
	var rng_core := RandomNumberGenerator.new()
	rng_core.seed = _mix_seed(_seed_value, _SEED_CORE)

	var base_bin: int = _pick_weighted_index_12(rng_core, spectrum_bin_weights)
	var base_h: float = (float(base_bin) + rng_core.randf()) / 12.0
	base_h = _wrap01(base_h)

	_col_core = Color.from_hsv(base_h, clampf(s, 0.0, 1.0), maxf(0.0, v), 1.0)

	# --- Determine a scheme per component (deterministic), allowing per-component overrides.
	var resolved_head: int = _resolve_component_scheme(head_scheme, _SEED_HEAD)
	var resolved_trail: int = _resolve_component_scheme(trail_scheme, _SEED_TRAIL)
	var resolved_rings: int = _resolve_component_scheme(rings_scheme, _SEED_RINGS)
	var resolved_sparks: int = _resolve_component_scheme(sparks_scheme, _SEED_SPARKS)

	if use_color_schemes:
		if not schemes_per_component:
			var one: int = _normalize_scheme(color_scheme, _SEED_SCHEMES)
			resolved_head = one
			resolved_trail = one
			resolved_rings = one
			resolved_sparks = one
		elif enforce_unique_component_schemes:
			var uniq := _make_unique_schemes(resolved_head, resolved_trail, resolved_rings, resolved_sparks)
			resolved_head = uniq[0]
			resolved_trail = uniq[1]
			resolved_rings = uniq[2]
			resolved_sparks = uniq[3]
	else:
		# No schemes: everything random hues (still deterministic)
		resolved_head = ColorScheme.RANDOM
		resolved_trail = ColorScheme.RANDOM
		resolved_rings = ColorScheme.RANDOM
		resolved_sparks = ColorScheme.RANDOM

	# --- Build anchored palettes (hues are relative to core hue, full spectrum supported)
	var head_pal: Array[Color] = _palette_for_scheme(resolved_head, base_h, s, v, _SEED_HEAD)
	var trail_pal: Array[Color] = _palette_for_scheme(resolved_trail, base_h, s, v, _SEED_TRAIL)
	var rings_pal: Array[Color] = _palette_for_scheme(resolved_rings, base_h, s, v, _SEED_RINGS)
	var sparks_pal: Array[Color] = _palette_for_scheme(resolved_sparks, base_h, s, v, _SEED_SPARKS)

	# Component picks:
	# - Head stays close to anchor
	# - Trail/Rings/Sparks prefer non-zero offset hue when possible
	_col_head_base = _pick_palette_color(head_pal, false, _SEED_HEAD)
	_col_head_core = _brighten(_col_head_base, 1.70)

	_col_trail_base = _pick_palette_color(trail_pal, true, _SEED_TRAIL)
	_col_trail_core = _brighten(_col_trail_base, 1.55)

	_col_rings = _pick_palette_color(rings_pal, true, _SEED_RINGS)
	_col_sparks = _pick_palette_color(sparks_pal, true, _SEED_SPARKS)

	# Sparks step gradient (threshold-like transitions)
	if sparks_use_full_spectrum_steps:
		var steps: int = maxi(2, sparks_step_count)
		var cols: Array[Color] = []
		cols.resize(steps)
		for i in range(steps):
			var hh: float = _wrap01(base_h + float(i) / float(steps))
			cols[i] = Color.from_hsv(hh, clampf(s, 0.0, 1.0), maxf(0.0, v), 1.0)
		_sparks_ramp_tex = _build_step_gradient(cols, steps)
	else:
		var cols2: Array[Color] = sparks_pal.duplicate()
		if cols2.is_empty():
			cols2 = [ _col_sparks, _brighten(_col_sparks, 1.25) ]
		_sparks_ramp_tex = _build_step_gradient(cols2, maxi(2, sparks_step_count))

func _resolve_component_scheme(override_scheme: int, salt: int) -> int:
	if not use_color_schemes:
		return ColorScheme.RANDOM
	if override_scheme > 0:
		return int(override_scheme)
	return _normalize_scheme(ColorScheme.RANDOM, salt)

func _normalize_scheme(scheme: int, salt: int) -> int:
	if scheme != ColorScheme.RANDOM:
		return int(scheme)
	var r := RandomNumberGenerator.new()
	r.seed = _mix_seed(_seed_value, salt)
	return r.randi_range(ColorScheme.MONOCHROMATIC, ColorScheme.TETRADIC)

func _make_unique_schemes(s0: int, s1: int, s2: int, s3: int) -> Array[int]:
	var r := RandomNumberGenerator.new()
	r.seed = _mix_seed(_seed_value, _SEED_SCHEMES)

	var pool: Array[int] = [1, 2, 3, 4, 5, 6]
	# Fisher-Yates shuffle using deterministic RNG
	for i in range(pool.size() - 1, 0, -1):
		var j: int = r.randi_range(0, i)
		var tmp: int = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp

	var out: Array[int] = [s0, s1, s2, s3]
	# Remove already-used explicit schemes from pool
	for k in range(4):
		if out[k] >= 1 and out[k] <= 6:
			pool.erase(out[k])

	# Fill any scheme==RANDOM with unique values
	for k in range(4):
		if out[k] == ColorScheme.RANDOM:
			if pool.is_empty():
				out[k] = r.randi_range(1, 6)
			else:
				out[k] = pool.pop_front()

	return out

func _palette_for_scheme(scheme: int, base_h: float, s: float, v: float, salt: int) -> Array[Color]:
	# Bin-delta scheme offsets (12-bin logic), but anchored to continuous base_h
	var deltas: Array[int] = _scheme_deltas(scheme)
	if deltas.is_empty():
		deltas = [0]

	var pal: Array[Color] = []
	pal.resize(deltas.size())

	for i in range(deltas.size()):
		var hh: float = _wrap01(base_h + float(deltas[i]) / 12.0)
		pal[i] = Color.from_hsv(hh, clampf(s, 0.0, 1.0), maxf(0.0, v), 1.0)

	# Deterministically shuffle non-zero entries (keep index 0 as the anchor color when possible)
	if pal.size() > 2:
		var r := RandomNumberGenerator.new()
		r.seed = _mix_seed(_seed_value, salt)
		for i in range(pal.size() - 1, 2, -1):
			var j: int = r.randi_range(1, i)
			var tmpc: Color = pal[i]
			pal[i] = pal[j]
			pal[j] = tmpc

	return pal

func _scheme_deltas(scheme: int) -> Array[int]:
	match scheme:
		ColorScheme.MONOCHROMATIC:
			return [0]
		ColorScheme.ANALOGOUS:
			return [0, 1, 11] # +1, -1
		ColorScheme.COMPLEMENTARY:
			return [0, 6]
		ColorScheme.TRIAD:
			return [0, 4, 8]
		ColorScheme.SPLIT_COMPLEMENTARY:
			return [0, 5, 7]
		ColorScheme.TETRADIC:
			return [0, 3, 6, 9]
		_:
			# RANDOM scheme: let caller pick a random scheme first; fallback here to "any hue"
			return [0, 2, 5, 8, 10]

func _pick_palette_color(pal: Array[Color], prefer_nonzero: bool, salt: int) -> Color:
	if pal.is_empty():
		return Color.WHITE
	if not prefer_nonzero or pal.size() == 1:
		return pal[0]
	var r := RandomNumberGenerator.new()
	r.seed = _mix_seed(_seed_value, salt ^ 0x1234ABCD)
	return pal[r.randi_range(1, pal.size() - 1)]

# ----------------------------- Gradient helpers -----------------------------

func _build_step_gradient(colors: Array[Color], steps: int) -> GradientTexture1D:
	var g: Gradient = Gradient.new()
	var n: int = maxi(1, steps)
	var eps: float = 0.0005

	# Hard-ish steps by duplicating points near boundaries.
	for i in range(n):
		var c: Color = colors[i % colors.size()]
		var t0: float = float(i) / float(n)
		var t1: float = float(i + 1) / float(n)

		g.add_point(clampf(t0 + eps, 0.0, 1.0), c)
		g.add_point(clampf(t1 - eps, 0.0, 1.0), c)

	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 256
	return tex

# ------------------------------ Noise texture -------------------------------

func _build_noise_texture(size: int, frequency: float, seed_value: int) -> Texture2D:
	var sz: int = maxi(32, size)
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RF)

	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = frequency
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX

	for y in range(sz):
		for x in range(sz):
			var fx: float = float(x) / float(sz)
			var fy: float = float(y) / float(sz)
			var v: float = n.get_noise_2d(fx * 10.0, fy * 10.0) # [-1..1]
			v = (v * 0.5) + 0.5
			img.set_pixel(x, y, Color(v, 0.0, 0.0, 1.0))

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	return tex

# ------------------------------ Node creation -------------------------------

func _ensure_extra_nodes() -> void:
	# Core inside head
	if _core == null:
		_core = MeshInstance3D.new()
		_core.name = "Core"
		_head.add_child(_core)
		_core.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

	# Rings root inside head
	if _rings_root == null:
		_rings_root = Node3D.new()
		_rings_root.name = "RingsRoot"
		_head.add_child(_rings_root)
		_rings_root.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

	if _rings_mesh == null:
		_rings_mesh = MeshInstance3D.new()
		_rings_mesh.name = "Rings"
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * 2.0
		_rings_mesh.mesh = quad
		_rings_root.add_child(_rings_mesh)
		_rings_mesh.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

	# Optional trail glow
	if _trail_glow == null:
		_trail_glow = MeshInstance3D.new()
		_trail_glow.name = "TrailGlow"
		_trail_glow.mesh = _trail.mesh
		_trail.add_child(_trail_glow)
		_trail_glow.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
		_trail_glow.visible = false

# ------------------------------ Rings anchor --------------------------------

func _sync_rings_to_head_center() -> void:
	if _rings_root == null or _head == null:
		return

	var local_center: Vector3 = Vector3.ZERO
	if rings_anchor_to_head_mesh and _head.mesh != null:
		var aabb: AABB = _head.mesh.get_aabb()
		local_center = aabb.position + (aabb.size * 0.5)

	_rings_root.position = local_center + rings_local_offset

# ------------------------------ Camera facing -------------------------------

func _get_camera() -> Camera3D:
	# Prefer viewport camera
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null:
		return cam
	# Fallback: look for a Camera3D node
	var n: Node = get_tree().root.find_child("Camera3D", true, false)
	return n as Camera3D

func _face_camera(n: Node3D, cam: Camera3D) -> void:
	var pos: Vector3 = n.global_position
	var dir: Vector3 = (cam.global_position - pos)
	if dir.length_squared() < 0.000001:
		return
	dir = dir.normalized()
	var basis: Basis = Basis.looking_at(dir, Vector3.UP)
	n.global_transform = Transform3D(basis, pos)

# ------------------------------ Preset getters ------------------------------

func _has_prop(obj: Object, key: StringName) -> bool:
	var plist: Array = obj.get_property_list()
	for i in range(plist.size()):
		var d: Dictionary = plist[i]
		if StringName(d.get("name", "")) == key:
			return true
	return false

func _p_int(key: StringName, fallback: int) -> int:
	if preset == null:
		return fallback
	if not _has_prop(preset, key):
		return fallback
	var v: Variant = preset.get(key)
	if typeof(v) == TYPE_INT:
		return int(v)
	if typeof(v) == TYPE_FLOAT:
		return int(v)
	return fallback

func _p_float(key: StringName, fallback: float) -> float:
	if preset == null:
		return fallback
	if not _has_prop(preset, key):
		return fallback
	var v: Variant = preset.get(key)
	if typeof(v) == TYPE_FLOAT:
		return float(v)
	if typeof(v) == TYPE_INT:
		return float(v)
	return fallback

# ----------------------------- Safe property set ----------------------------

func _set_prop_if_exists(obj: Object, prop: StringName, value: Variant) -> void:
	if obj == null:
		return
	if not _has_prop(obj, prop):
		return
	obj.set(prop, value)

# ------------------------------ Small helpers -------------------------------

func _wrap01(x: float) -> float:
	return fposmod(x, 1.0)

func _brighten(c: Color, mul: float) -> Color:
	return Color(c.r * mul, c.g * mul, c.b * mul, c.a)

func _pick_weighted_index_12(r: RandomNumberGenerator, w: PackedFloat32Array) -> int:
	var total: float = 0.0
	var has12: bool = (w.size() == 12)

	for i in range(12):
		var wi: float = 1.0
		if has12:
			wi = maxf(0.0, float(w[i]))
		total += wi

	if total <= 0.000001:
		return r.randi_range(0, 11)

	var t: float = r.randf() * total
	var acc: float = 0.0
	for i in range(12):
		var wi2: float = 1.0
		if has12:
			wi2 = maxf(0.0, float(w[i]))
		acc += wi2
		if t <= acc:
			return i

	return 11

func _mix_seed(a: int, b: int) -> int:
	# Simple 32-bit-ish mix (deterministic)
	var x: int = a ^ b
	x = int((x ^ (x >> 16)) * 0x7FEB352D) & 0x7FFFFFFF
	x = int((x ^ (x >> 15)) * 0x846CA68B) & 0x7FFFFFFF
	x = x ^ (x >> 16)
	return x

# -------------------------------- Shaders ----------------------------------

func _shader_head() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

uniform sampler2D noise_tex;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float distort_strength = 0.25;
uniform float glow_strength = 2.25;
uniform float core_power = 2.3;

void fragment() {
	vec2 uv = UV;
	float n = texture(noise_tex, uv * 2.0 + vec2(TIME * 0.05, TIME * 0.03)).r;
	float mask = pow(1.0 - clamp(length(uv * 2.0 - 1.0), 0.0, 1.0), core_power);

	vec3 col = mix(base_color.rgb, core_color.rgb, mask);
	float a = clamp(0.15 + n * (0.85 + distort_strength), 0.0, 1.0);

	ALBEDO = col;
	EMISSION = col * glow_strength;
	ALPHA = a;
}
"""
	return sh

func _shader_core() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

uniform sampler2D noise_tex;
uniform vec4 core_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float glow_strength = 2.5;

void fragment() {
	float n = texture(noise_tex, UV * 3.0 + vec2(TIME * 0.07, TIME * 0.02)).r;
	float a = clamp(0.35 + n * 0.75, 0.0, 1.0);
	vec3 col = core_color.rgb;

	ALBEDO = col;
	EMISSION = col * glow_strength;
	ALPHA = a;
}
"""
	return sh

func _shader_trail() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

uniform sampler2D noise_tex;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float distort_strength = 0.18;
uniform float glow_strength = 1.8;

void fragment() {
	vec2 uv = UV;
	float flow = TIME * 0.25;
	float n = texture(noise_tex, uv * vec2(3.0, 1.5) + vec2(flow, flow * 0.3)).r;

	// Fade along V (supports many meshes)
	float t = clamp(uv.y, 0.0, 1.0);
	float fade = pow(1.0 - t, 1.6);

	vec3 col = mix(base_color.rgb, core_color.rgb, smoothstep(0.0, 1.0, 1.0 - t));
	float a = clamp((0.15 + n * (0.75 + distort_strength)) * fade, 0.0, 1.0);

	ALBEDO = col;
	EMISSION = col * glow_strength * (0.5 + 0.5 * fade);
	ALPHA = a;
}
"""
	return sh

func _shader_rings() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform int ring_count = 4;
uniform float thickness = 0.06;
uniform float softness = 0.06;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);

	// Repeat rings
	float band = fract(r * float(ring_count));
	float d = abs(band - 0.5);

	float ring = 1.0 - smoothstep(thickness, thickness + softness, d);
	// Soft outer fade
	float outer = 1.0 - smoothstep(0.95, 1.05, r);

	float a = clamp(ring * outer, 0.0, 1.0);

	ALBEDO = ring_color.rgb;
	EMISSION = ring_color.rgb * (2.0 * a);
	ALPHA = a;
}
"""
	return sh

func _shader_sparks_draw() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	// simple soft sprite from UV
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = 1.0 - smoothstep(0.15, 1.0, r);
	vec3 col = tint.rgb;

	ALBEDO = col;
	EMISSION = col * (2.0 * a);
	ALPHA = a;
}
"""
	return sh
