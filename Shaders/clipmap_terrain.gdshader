shader_type spatial;
render_mode cull_back, depth_draw_opaque, world_vertex_coords;

// Heightmap and texturing
uniform sampler2D heightmap : filter_linear_mipmap, repeat_enable;
uniform sampler2D heightmap_normals : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float heightmap_scale : hint_range(0.0, 1.0) = 0.01;
uniform float heightmap_height_scale : hint_range(0.0, 100.0) = 20.0;

// LIMINAL/HORROR TERRAIN COLORS - Desaturated, eerie, uncanny
uniform vec4 color_low : source_color = vec4(0.18, 0.20, 0.18, 1.0);   // Dark murky gray-green
uniform vec4 color_mid : source_color = vec4(0.28, 0.30, 0.26, 1.0);   // Sickly pale olive
uniform vec4 color_high : source_color = vec4(0.35, 0.35, 0.32, 1.0);  // Washed-out gray

// Slope-based coloring
uniform sampler2D slope_edge_noise : filter_linear_mipmap, repeat_enable;
uniform float slope_edge_noise_scale : hint_range(0.0, 10.0) = 1.0;
uniform vec4 slope_color : source_color = vec4(0.22, 0.20, 0.18, 1.0); // Dark muddy brown
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.6;

// Liminal space effects
uniform float fog_blend : hint_range(0.0, 1.0) = 0.3; // Blend terrain into fog
uniform float desaturation : hint_range(0.0, 1.0) = 0.7; // Remove color vibrancy
uniform vec3 fog_tint : source_color = vec3(0.15, 0.16, 0.15); // Greenish-gray fog tint

// Subtle distortion for unease
uniform float time_scale : hint_range(0.0, 1.0) = 0.05;
uniform float distortion_strength : hint_range(0.0, 0.5) = 0.02;

// Camera following (for "wandering" clipmap)
uniform vec3 camera_position;
uniform float mesh_size = 512.0;

varying vec3 world_position;
varying float height_value;
varying vec2 terrain_uv;
varying float distance_to_camera;

void vertex() {
	// Get world position (mesh is already positioned by script)
	vec3 vertex_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Calculate UV for heightmap sampling (world space - stays consistent)
	terrain_uv = vertex_world.xz * heightmap_scale;

	// Sample heightmap
	float height = texture(heightmap, terrain_uv).r;
	height_value = height;

	// Apply height displacement
	VERTEX.y = height * heightmap_height_scale;

	// Subtle vertex distortion for unease (very subtle breathing effect)
	float distortion = sin(TIME * time_scale + vertex_world.x * 0.1 + vertex_world.z * 0.1) * distortion_strength;
	VERTEX.y += distortion;

	// Store world position for fragment shader
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Calculate distance to camera for fog effects
	distance_to_camera = length(camera_position - world_position);
}

void fragment() {
	// Sample normal map
	vec3 normal_map = texture(heightmap_normals, terrain_uv).rgb;
	NORMAL_MAP = normal_map;

	// Height-based coloring with subtle, unsettling transitions
	vec3 base_color;
	if (height_value < 0.4) {
		// Low areas - dark, murky
		base_color = mix(color_low.rgb, color_mid.rgb, height_value / 0.4);
	} else if (height_value < 0.7) {
		// Mid areas - sickly pale
		base_color = mix(color_mid.rgb, color_high.rgb, (height_value - 0.4) / 0.3);
	} else {
		// High areas - washed out
		base_color = color_high.rgb;
	}

	// Slope-based coloring (for cliffs/steep areas)
	float slope = 1.0 - NORMAL.y; // 0 = flat, 1 = vertical
	float slope_noise = texture(slope_edge_noise, terrain_uv * slope_edge_noise_scale).r;
	float slope_factor = smoothstep(slope_threshold - 0.1, slope_threshold + 0.1, slope + slope_noise * 0.2);

	// Mix in slope color for steep areas
	base_color = mix(base_color, slope_color.rgb, slope_factor * 0.5);

	// LIMINAL SPACE EFFECTS

	// 1. Desaturate for that washed-out, dreamlike quality
	float luminance = dot(base_color, vec3(0.299, 0.587, 0.114));
	base_color = mix(base_color, vec3(luminance), desaturation);

	// 2. Blend with fog tint for atmospheric horror
	float fog_factor = smoothstep(0.0, 200.0, distance_to_camera);
	base_color = mix(base_color, fog_tint, fog_factor * fog_blend);

	// 3. Add subtle noise/grain for unease
	float grain = fract(sin(dot(world_position.xz, vec2(12.9898, 78.233))) * 43758.5453);
	base_color += (grain - 0.5) * 0.03;

	ALBEDO = base_color;
	ROUGHNESS = 0.95; // Very matte, no shine
	METALLIC = 0.0;
	SPECULAR = 0.05; // Almost no specular highlights

	// Slight emission for eerie glow in dark areas
	EMISSION = base_color * 0.02;
}

