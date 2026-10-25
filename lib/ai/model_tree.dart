import 'model_catalog.dart';
import 'provider_config.dart';

/// One model in a list: [key] is what the list reports when it is picked.
class TreeLeaf {
  const TreeLeaf(this.key, this.title, {this.subtitle = '', this.badge});

  final String key;
  final String title;

  /// What is known about the model (context window, images, reasoning); may be empty.
  final String subtitle;

  /// A short mark such as 設定済み; null for none.
  final String? badge;
}

/// A folder of the list: a maker, a provider, or "recently used".
class TreeNode {
  const TreeNode(this.key, this.label, {this.leaves = const [], this.children = const []});

  final String key;
  final String label;
  final List<TreeLeaf> leaves;
  final List<TreeNode> children;

  /// All the models below this folder.
  int get count => leaves.length + children.fold(0, (sum, child) => sum + child.count);

  bool contains(String leafKey) => leaves.any((l) => l.key == leafKey) || children.any((c) => c.contains(leafKey));
}

/// What a model list shows: models that stand alone at the top, then folders.
class TreeModel {
  const TreeModel(this.rootLeaves, this.nodes);

  final List<TreeLeaf> rootLeaves;
  final List<TreeNode> nodes;

  bool get isEmpty => rootLeaves.isEmpty && nodes.isEmpty;
}

/// Builds the lists for the model screens: the models of one provider, grouped by maker, and the
/// models of every provider, for the places that choose a model for a job (the coding mode).
abstract final class ModelTrees {
  /// `200000` → `200K`, `131072` → `128K`, `1048576` → `1M`; what the lists show beside a model.
  /// Providers write limits both as round decimals (200000) and as powers of two (131072), so a
  /// value close to either is shown as the round number.
  static String sizeLabel(int tokens) {
    if (tokens >= 1000000) return _round(tokens / 1048576, tokens / 1000000, 'M');
    if (tokens >= 1000) return _round(tokens / 1024, tokens / 1000, 'K');
    return '$tokens';
  }

  static String _round(double binary, double decimal, String unit) {
    String fmt(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
    // the nearer of the two readings that is a whole number wins: 131072 → 128K, 200000 → 200K
    final b = (binary - binary.round()).abs();
    final d = (decimal - decimal.round()).abs();
    return '${fmt(b <= d ? binary.roundToDouble() : decimal.roundToDouble())}$unit';
  }

  static String infoLine({int? context, int? output, bool? vision, bool? reasoning}) => [
        if (context != null) '文脈 ${sizeLabel(context)}',
        if (output != null) '出力 ${sizeLabel(output)}',
        if (vision == true) '画像',
        if (reasoning == true) '思考',
      ].join(' · ');

  /// The title of a model in a list: without its maker's prefix (the folder already says it).
  static String titleOf(String id) {
    final slash = id.indexOf('/');
    return slash > 0 && slash < id.length - 1 ? id.substring(slash + 1) : id;
  }

  static TreeLeaf _leaf(ProviderConfig config, String id, {String Function(String)? key, String? title}) {
    final saved = config.modelById(id);
    final info = config.catalogInfo(id);
    return TreeLeaf(
      key == null ? id : key(id),
      title ?? titleOf(id),
      subtitle: infoLine(
        context: saved?.contextTokens ?? info?.contextTokens,
        output: saved?.maxOutputTokens ?? info?.maxOutputTokens,
        vision: saved?.vision ?? info?.vision,
        reasoning: info?.reasoning,
      ),
      badge: saved != null ? '設定済み' : null,
    );
  }

  /// The vendor folders of [ids], with each model built by [leaf].
  static List<TreeNode> _byMaker(String prefix, Iterable<String> ids, String query, TreeLeaf Function(String) leaf) => [
        for (final group in ModelCatalog.group(ids, query: query))
          TreeNode('$prefix${group.key}', group.label, leaves: [for (final id in group.ids) leaf(id)]),
      ];

  /// The models of one provider: "recently used" first, then a folder per maker. Leaves are keyed
  /// by the model id.
  static TreeModel forProvider(ProviderConfig config, {String query = '', List<String> recent = const []}) {
    final known = config.knownIds.toSet();
    final recentIds = [
      for (final ref in recent)
        if (ref.startsWith('${config.id}|') && known.contains(ref.substring(config.id.length + 1)) && ModelCatalog.matches(ref.substring(config.id.length + 1), query))
          ref.substring(config.id.length + 1),
    ];
    return TreeModel(const [], [
      if (recentIds.isNotEmpty)
        TreeNode('recent', '最近使った', leaves: [for (final id in recentIds) _leaf(config, id, title: id)]),
      ..._byMaker('maker:', config.knownIds, query, (id) => _leaf(config, id)),
    ]);
  }

  /// A provider with this many models or fewer is shown as one flat list in the picker.
  static const flatLimit = 8;

  /// The models of every provider, for choosing one for a job. Leaves are keyed `provider|model`
  /// (the form the coding settings keep). [rootLeaves] come first: the device model and "not chosen"
  /// when the caller offers them.
  static TreeModel forPicker(
    List<ProviderConfig> providers, {
    String query = '',
    List<String> recent = const [],
    List<TreeLeaf> rootLeaves = const [],
  }) {
    final byId = {for (final p in providers) p.id: p};
    final recentLeaves = <TreeLeaf>[];
    for (final ref in recent) {
      final bar = ref.indexOf('|');
      if (bar <= 0) continue;
      final provider = byId[ref.substring(0, bar)];
      final model = ref.substring(bar + 1);
      if (provider == null || !provider.knownIds.contains(model)) continue;
      if (!ModelCatalog.matches('${provider.label} $model', query)) continue;
      recentLeaves.add(_leaf(provider, model, key: (id) => '${provider.id}|$id', title: '${provider.label} · $model'));
    }

    final nodes = <TreeNode>[
      if (recentLeaves.isNotEmpty) TreeNode('recent', '最近使った', leaves: recentLeaves),
    ];
    for (final provider in providers) {
      final label = provider.label.isEmpty ? provider.id : provider.label;
      // a search matches the provider's name too: "orca claude" finds the Claude models of Orca
      final ids = [
        for (final id in provider.knownIds)
          if (ModelCatalog.matches('$label $id', query)) id,
      ];
      if (ids.isEmpty) continue;
      TreeLeaf leaf(String id) => _leaf(provider, id, key: (m) => '${provider.id}|$m');
      if (ids.length <= flatLimit) {
        // no maker folders here, so the whole id is the title
        nodes.add(TreeNode('p:${provider.id}', label, leaves: [for (final id in ids) _leaf(provider, id, key: (m) => '${provider.id}|$m', title: id)]));
      } else {
        nodes.add(TreeNode('p:${provider.id}', label, children: _byMaker('p:${provider.id}:maker:', ids, '', leaf)));
      }
    }
    final roots = [
      for (final leaf in rootLeaves)
        if (ModelCatalog.matches(leaf.title, query)) leaf,
    ];
    return TreeModel(roots, nodes);
  }
}
