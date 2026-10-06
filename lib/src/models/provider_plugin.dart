class ProviderPlugin {
  const ProviderPlugin({
    required this.id,
    required this.name,
    required this.filename,
    this.description = '',
    this.supportedTypes = const ['movie', 'tv'],
    this.priority = 0,
    this.enabled = true,
  });

  final String id, name, filename, description;
  final List<String> supportedTypes;
  final int priority;
  final bool enabled;

  ProviderPlugin copyWith({bool? enabled}) => ProviderPlugin(
    id: id,
    name: name,
    filename: filename,
    description: description,
    supportedTypes: supportedTypes,
    priority: priority,
    enabled: enabled ?? this.enabled,
  );

  factory ProviderPlugin.fromJson(Map<String, dynamic> json) => ProviderPlugin(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? json['id'] ?? 'Provider'}',
    filename: '${json['filename'] ?? json['file'] ?? json['script'] ?? ''}',
    description: '${json['description'] ?? ''}',
    supportedTypes: (json['supportedTypes'] as List? ?? const ['movie', 'tv'])
        .map((type) => '$type')
        .toList(),
    priority: int.tryParse('${json['priority'] ?? 0}') ?? 0,
    enabled: json['enabled'] != false,
  );
}

class ProviderRepository {
  const ProviderRepository({
    required this.url,
    required this.name,
    this.plugins = const [],
  });

  final String url, name;
  final List<ProviderPlugin> plugins;

  factory ProviderRepository.fromJson(
    String url,
    String name,
    List<dynamic> json,
  ) => ProviderRepository(
    url: url,
    name: name,
    plugins: json
        .whereType<Map>()
        .map((entry) => ProviderPlugin.fromJson(Map<String, dynamic>.from(entry)))
        .where((plugin) => plugin.id.isNotEmpty && plugin.filename.isNotEmpty)
        .toList(),
  );
}
