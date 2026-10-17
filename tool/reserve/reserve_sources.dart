// What each provider says, read from its own PUBLIC, keyless pages and model lists. Nothing here
// uses an account, an API key or an inference request, so nothing is spent. The fetch function is
// injected so the same code is tested without a network.
import 'dart:convert';
import 'dart:io';

typedef Fetch = Future<String> Function(String url);

Future<String> httpFetch(String url) async {
  final client = HttpClient()..userAgent = 'EmanLifeCatalogueCheck/1';
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 40));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    return await utf8.decodeStream(response);
  } finally {
    client.close(force: true);
  }
}

String plainText(String html) => html
    .replaceAll(RegExp(r'<script[\s\S]*?</script>'), ' ')
    .replaceAll(RegExp(r'<style[\s\S]*?</style>'), ' ')
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ');

/// One provider's public source, or the reason it could not be read. A source that could not be
/// read, or that read implausibly, is never evidence that a model is gone.
class Source {
  const Source.ok(this.size, this.data) : problem = null;
  const Source.failed(this.problem) : size = 0, data = null;
  final int size;
  final Object? data;
  final String? problem;
  bool get usable => problem == null;
}

class Sources {
  Sources(this.bySource);
  final Map<String, Source> bySource;
  Source of(String name) =>
      bySource[name] ?? const Source.failed('not fetched');
}

/// [previousSizes] guards against a partial list: a list much shorter than the last good one is
/// treated as unreadable, not as proof that the missing models are gone.
Future<Sources> fetchSources(
  Fetch fetch, {
  Map<String, int> previousSizes = const {},
}) async {
  final out = <String, Source>{};
  Future<void> load(String name, Future<Source> Function() read) async {
    try {
      final source = await read();
      final before = previousSizes[name];
      if (source.usable &&
          before != null &&
          before > 0 &&
          source.size < before * 0.5) {
        out[name] = Source.failed(
          'list has ${source.size} entries, was $before: treated as unreadable',
        );
      } else {
        out[name] = source;
      }
    } on Object catch (e) {
      out[name] = Source.failed('$e');
    }
  }

  await load('openrouter', () async {
    final data =
        (jsonDecode(await fetch('https://openrouter.ai/api/v1/models'))
                as Map)['data']
            as List;
    return Source.ok(data.length, {
      for (final m in data) (m as Map)['id'] as String: m,
    });
  });
  await load('nvidia', () async {
    final data =
        (jsonDecode(await fetch('https://integrate.api.nvidia.com/v1/models'))
                as Map)['data']
            as List;
    return Source.ok(data.length, {
      for (final m in data) (m as Map)['id'] as String,
    });
  });
  await load('gemini-models', () async {
    final text = plainText(
      await fetch('https://ai.google.dev/gemini-api/docs/models'),
    );
    return Source.ok(
      RegExp(r'gemini-[0-9][0-9a-z.-]*').allMatches(text).length,
      text,
    );
  });
  await load('gemini-pricing', () async {
    final text = plainText(
      await fetch('https://ai.google.dev/gemini-api/docs/pricing'),
    );
    return Source.ok(
      RegExp(r'gemini-[0-9][0-9a-z.-]*').allMatches(text).length,
      text,
    );
  });
  await load('zai', () async {
    final text = plainText(
      await fetch('https://docs.z.ai/guides/overview/pricing'),
    );
    return Source.ok(
      RegExp(r'GLM-[0-9][0-9A-Za-z.-]*').allMatches(text).length,
      text,
    );
  });
  await load('agnes', () async {
    final text = plainText(
      await fetch('https://wiki.agnes-ai.com/en/docs/agnes-30-flash'),
    );
    return Source.ok(text.length, text);
  });
  return Sources(out);
}

enum Seen { confirmed, absent, notFree, unreachable, manual }

class Observation {
  const Observation(this.seen, this.note, this.source);
  final Seen seen;
  final String note;
  final String source;
  Map<String, Object?> toJson() => {
    'seen': seen.name,
    'note': note,
    'source': source,
  };
}

/// What the providers' own sources say about one manifest entry. `absent` and `notFree` are only
/// returned from a source that was read successfully and plausibly.
Observation observe(Map<String, dynamic> model, Sources sources) {
  final provider = model['provider'] as String;
  final id = model['model'] as String;
  Observation unreadable(Source s, String url) =>
      Observation(Seen.unreachable, s.problem ?? 'unreadable', url);
  switch (provider) {
    case 'openrouter':
      const url = 'https://openrouter.ai/api/v1/models';
      final s = sources.of('openrouter');
      if (!s.usable) return unreadable(s, url);
      final entry = (s.data as Map)[id] as Map?;
      if (entry == null) {
        return const Observation(
          Seen.absent,
          'not in the provider model list',
          url,
        );
      }
      final pricing = entry['pricing'] as Map? ?? const {};
      final free =
          '${pricing['prompt']}' == '0' && '${pricing['completion']}' == '0';
      return free
          ? const Observation(Seen.confirmed, 'listed, priced at zero', url)
          : const Observation(
              Seen.notFree,
              'listed but not priced at zero',
              url,
            );
    case 'nvidia':
      const url = 'https://integrate.api.nvidia.com/v1/models';
      final s = sources.of('nvidia');
      if (!s.usable) return unreadable(s, url);
      // The list shows availability only; the trial terms are not machine-readable.
      return (s.data as Set).contains(id)
          ? const Observation(
              Seen.confirmed,
              'listed by the hosted API (trial terms not machine-readable)',
              url,
            )
          : const Observation(
              Seen.absent,
              'not in the hosted API model list',
              url,
            );
    case 'gemini':
      const url = 'https://ai.google.dev/gemini-api/docs/models';
      final a = sources.of('gemini-models');
      final b = sources.of('gemini-pricing');
      if (!a.usable) return unreadable(a, url);
      if (!b.usable) return unreadable(b, url);
      final exact = RegExp('(?<![\\w.-])${RegExp.escape(id)}(?![\\w.-])');
      return exact.hasMatch(a.data as String) &&
              exact.hasMatch(b.data as String)
          ? const Observation(
              Seen.confirmed,
              'listed on the models and pricing pages (free-tier flag is the owner\'s)',
              url,
            )
          : const Observation(
              Seen.absent,
              'not on the provider model pages',
              url,
            );
    case 'zai':
      const url = 'https://docs.z.ai/guides/overview/pricing';
      final s = sources.of('zai');
      if (!s.usable) return unreadable(s, url);
      final name = id.replaceAll('-', '[-\\s]?');
      final free = RegExp(
        '$name\\s*\\|?\\s*Free\\s*\\|?\\s*Free',
        caseSensitive: false,
      );
      final listed = RegExp(name, caseSensitive: false);
      if (free.hasMatch(s.data as String)) {
        return const Observation(
          Seen.confirmed,
          'listed as free on the pricing page',
          url,
        );
      }
      return listed.hasMatch(s.data as String)
          ? const Observation(Seen.notFree, 'listed but not as free', url)
          : const Observation(Seen.absent, 'not on the pricing page', url);
    case 'agnes':
      const url = 'https://wiki.agnes-ai.com/en/docs/agnes-30-flash';
      final s = sources.of('agnes');
      if (!s.usable) return unreadable(s, url);
      final named = (s.data as String).contains(id);
      final zero = RegExp(r'currently\s*`?\$0').hasMatch(s.data as String);
      if (!named) {
        return const Observation(
          Seen.absent,
          'model page does not name the model',
          url,
        );
      }
      return zero
          ? const Observation(
              Seen.confirmed,
              'priced at zero on the model page',
              url,
            )
          : const Observation(
              Seen.notFree,
              'model page no longer states a zero price',
              url,
            );
    default:
      // Alibaba Model Studio states eligibility per model inside the account console.
      return const Observation(
        Seen.manual,
        'no keyless machine-readable source',
        '',
      );
  }
}

/// Free models a provider's list shows that the manifest does not know. They are reported for
/// review and never added: whether one suits EmanLife (privacy, tools, context, terms) is a judgement.
List<Map<String, Object?>> discoverCandidates(
  Sources sources,
  Set<String> knownKeys,
) {
  final out = <Map<String, Object?>>[];
  final s = sources.of('openrouter');
  if (s.usable) {
    for (final e in (s.data as Map).entries) {
      final id = e.key as String;
      if (!id.endsWith(':free') || knownKeys.contains('openrouter/$id')) {
        continue;
      }
      final m = e.value as Map;
      final pricing = m['pricing'] as Map? ?? const {};
      if ('${pricing['prompt']}' != '0' || '${pricing['completion']}' != '0') {
        continue;
      }
      out.add({
        'provider': 'openrouter',
        'model': id,
        'context': m['context_length'],
        'source': 'https://openrouter.ai/api/v1/models',
      });
    }
  }
  return out;
}
