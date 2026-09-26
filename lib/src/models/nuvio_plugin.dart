class NuvioPlugin {
  const NuvioPlugin({
    required this.id,
    required this.name,
    required this.filename,
    this.description = '',
    this.supportedTypes = const ['movie', 'tv'],
    this.enabled = true,
  });

  final String id, name, filename, description;
  final List<String> supportedTypes;
  final bool enabled;

  NuvioPlugin copyWith({bool? enabled}) => NuvioPlugin(
    id: id,
    name: name,
    filename: filename,
    description: description,
    supportedTypes: supportedTypes,
    enabled: enabled ?? this.enabled,
  );

  factory NuvioPlugin.fromJson(Map<String, dynamic> json) => NuvioPlugin(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? json['id'] ?? 'Provider'}',
    filename: '${json['filename'] ?? json['file'] ?? json['script'] ?? ''}',
    description: '${json['description'] ?? ''}',
    supportedTypes: (json['supportedTypes'] as List? ?? const ['movie', 'tv'])
        .map((type) => '$type')
        .toList(),
    enabled: json['enabled'] != false,
  );
}

class NuvioPluginRepository {
  const NuvioPluginRepository({
    required this.url,
    required this.name,
    this.plugins = const [],
  });

  final String url, name;
  final List<NuvioPlugin> plugins;

  factory NuvioPluginRepository.fromJson(
    String url,
    String name,
    List<dynamic> json,
  ) => NuvioPluginRepository(
    url: url,
    name: name,
    plugins: json
        .whereType<Map>()
        .map((entry) => NuvioPlugin.fromJson(Map<String, dynamic>.from(entry)))
        .where((plugin) => plugin.id.isNotEmpty && plugin.filename.isNotEmpty)
        .toList(),
  );
}
