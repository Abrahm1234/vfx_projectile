# res://VFX/Scripts/vfx_preset.gd
extends Resource
class_name VFXPreset

@export var name: String = "Default"

# Palette source (optional; scheme-colors can override in projectile)
@export var use_gradient_palette: bool = true
@export var gradient: Gradient

@export_range(0.0, 1.0, 0.001) var hue_min: float = 0.0
@export_range(0.0, 1.0, 0.001) var hue_max: float = 1.0
@export_range(0.0, 1.0, 0.001) var sat_min: float = 0.75
@export_range(0.0, 1.0, 0.001) var sat_max: float = 1.00
@export_range(0.0, 2.0, 0.001) var val_min: float = 0.70
@export_range(0.0, 3.0, 0.001) var val_max: float = 1.60

@export_range(0.0, 10.0, 0.01) var emiss_energy_head: float = 2.5
@export_range(0.0, 10.0, 0.01) var emiss_energy_core: float = 3.0
@export_range(0.0, 10.0, 0.01) var emiss_energy_trail: float = 2.0
@export_range(0.0, 10.0, 0.01) var emiss_energy_trail_glow: float = 1.5
@export_range(0.0, 10.0, 0.01) var emiss_energy_rings: float = 2.0
@export_range(0.0, 10.0, 0.01) var emiss_energy_sparks: float = 2.0

# Noise
@export var noise_texture: Texture2D
@export_range(16, 1024, 1) var noise_size: int = 256
@export_range(0.1, 20.0, 0.1) var noise_frequency: float = 6.0

@export var uv_scale: Vector2 = Vector2(1.0, 1.0)
@export var uv_scroll: Vector2 = Vector2(1.2, 0.0)
@export var secondary_scroll: Vector2 = Vector2(-0.4, 0.0)

# Trail taper + glow
@export_range(0.01, 3.0, 0.01) var trail_width_start: float = 1.0
@export_range(0.00, 3.0, 0.01) var trail_width_end: float = 0.05
@export var trail_glow_enabled: bool = true
@export_range(1.0, 3.0, 0.01) var trail_glow_width_mul: float = 1.35
@export_range(0.0, 1.0, 0.01) var trail_glow_alpha: float = 0.6

# Head pulse/distortion
@export_range(0.0, 1.0, 0.001) var head_distort_amount: float = 0.12
@export_range(0.0, 20.0, 0.01) var head_distort_speed: float = 5.0

# Core (internal mesh)
@export var core_enabled: bool = true
@export var core_mesh: Mesh
@export_range(0.05, 1.0, 0.01) var core_scale: float = 0.55
@export_range(0.0, 1.0, 0.001) var core_distort_amount: float = 0.08
@export_range(0.0, 20.0, 0.01) var core_distort_speed: float = 4.0

# Rings
@export var rings_enabled: bool = true
@export_range(0.01, 5.0, 0.01) var ring_radius_m: float = 0.45
@export_range(0.001, 2.0, 0.001) var ring_thickness_m: float = 0.06
@export_range(0.0, 1.0, 0.001) var ring_pulse_amount: float = 0.08
@export_range(0.0, 20.0, 0.01) var ring_pulse_speed: float = 3.5

# Sparks
@export_range(0.0, 200.0, 0.1) var spark_rate: float = 40.0
@export_range(0.1, 20.0, 0.1) var spark_lifetime: float = 0.6
@export_range(0.0, 30.0, 0.1) var spark_speed_min: float = 1.5
@export_range(0.0, 30.0, 0.1) var spark_speed_max: float = 5.0
@export_range(0.01, 2.0, 0.01) var spark_size_min: float = 0.03
@export_range(0.01, 2.0, 0.01) var spark_size_max: float = 0.08
@export_range(0.0, 6.28, 0.001) var spark_spread: float = 0.9
@export_range(0.0, 10.0, 0.01) var spark_orbit_min: float = 0.0
@export_range(0.0, 10.0, 0.01) var spark_orbit_max: float = 2.2
