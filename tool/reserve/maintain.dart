// The scheduled catalogue check. It runs on a computer (a scheduled workflow), never on the phone,
// and asks only each provider's own public, keyless pages and model lists: no key, no inference,
// nothing spent. It decides conservatively (see maintain_policy.dart), writes what it decided and
// why, and writes a new unsigned manifest ONLY when something is to be published. Signing is a
// separate step (sign.dart), so this program never holds a key.
//
//   dart run tool/reserve/maintain.dart --manifest <current manifest.json> --state <state.json>
//        --out <directory> [--today YYYY-MM-DD]
//
// Exit status: 0 nothing to publish, 10 a new manifest was written, 20 only held items, 1 failure.
import 'dart:convert';
import 'dart:io';

import 'maintain_policy.dart';
import 'reserve_sources.dart';

String _arg(List<String> args, String name, [String? fallback]) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  if (fallback != null) return fallback;
  stderr.writeln('missing $name');
  exit(64);
}

Future<void> main(List<String> args) async {
  final now = DateTime.now().toUtc();
  final today = _arg(
    args,
    '--today',
    '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
  );
  final manifestFile = File(_arg(args, '--manifest'));
  final stateFile = File(_arg(args, '--state'));
  final out = Directory(_arg(args, '--out'))..createSync(recursive: true);
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final state = stateFile.existsSync()
      ? jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{'schema': 1};
  final sizes = <String, int>{
    for (final e
        in ((state['sources'] ?? <String, dynamic>{}) as Map<String, dynamic>)
            .entries)
      e.key: (e.value as Map)['size'] as int,
  };

  final requested = <String>[];
  final sources = await fetchSources((url) {
    requested.add(url);
    return httpFetch(url);
  }, previousSizes: sizes);
  final models = (manifest['models'] as List).cast<Map<String, dynamic>>();
  final observations = {
    for (final m in models)
      '${m['provider']}/${m['model']}': observe(m, sources),
  };
  final candidates =
      discoverCandidates(sources, {
          for (final m in models) '${m['provider']}/${m['model']}',
        })
        // Reviewed and deliberately left out earlier: not reported again every day.
        ..removeWhere(
          (c) => ((state['reviewed'] ?? const <dynamic>[]) as List).contains(
            '${c['provider']}/${c['model']}',
          ),
        );

  // How old an evidence date may be before a confirmed model's date is renewed. Normally 45 days; a
  // person running the workflow by hand may ask for a different number (0 renews every confirmed
  // model now, which is true because it was just confirmed).
  final refreshAfter = int.tryParse(_arg(args, '--refresh-after-days', '45'));
  if (refreshAfter == null || refreshAfter < 0 || refreshAfter > 365) {
    stderr.writeln('--refresh-after-days must be a number from 0 to 365');
    exit(64);
  }

  final decision = decide(
    policy: Policy(refreshAfterDays: refreshAfter),
    manifest: manifest,
    state: state,
    observations: observations,
    candidates: candidates,
    today: today,
  );

  // A context window that differs from the one on record is for a person to look at.
  final openRouter = sources.of('openrouter');
  final held = [...decision.held];
  if (openRouter.usable) {
    for (final m in models.where((m) => m['provider'] == 'openrouter')) {
      final live = (openRouter.data as Map)[m['model']] as Map?;
      if (live != null &&
          live['context_length'] != null &&
          live['context_length'] != m['context']) {
        held.add(
          Held(
            'context_changed',
            'openrouter/${m['model']}',
            'listed context ${live['context_length']}, on record ${m['context']}',
          ),
        );
      }
    }
  }

  // Remember how big each readable list was, to recognise a truncated one tomorrow.
  final next = decision.state;
  final remembered =
      (next['sources'] ??= <String, dynamic>{}) as Map<String, dynamic>;
  for (final e in sources.bySource.entries) {
    if (e.value.usable) {
      remembered[e.key] = {'size': e.value.size, 'last_ok': today};
    }
  }
  next['last_run'] = today;
  stateFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(next)}\n',
  );

  final report = {
    'date': today,
    'published': decision.publishes,
    'version_before': manifest['version'],
    'version_after': decision.manifest?['version'] ?? manifest['version'],
    'changes': [for (final c in decision.changes) c.toJson()],
    'held': [for (final h in held) h.toJson()],
    'requests': requested,
    'observations': {
      for (final e in observations.entries) e.key: e.value.toJson(),
    },
    'sources': {
      for (final e in sources.bySource.entries)
        e.key: e.value.usable
            ? {'ok': true, 'size': e.value.size}
            : {'ok': false, 'problem': e.value.problem},
    },
  };
  File('${out.path}/decision.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  if (decision.publishes) {
    File('${out.path}/manifest.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(decision.manifest)}\n',
    );
  }
  final counts = <String, int>{};
  for (final o in observations.values) {
    counts[o.seen.name] = (counts[o.seen.name] ?? 0) + 1;
  }
  stdout.writeln(
    '$today observations: $counts; changes: ${decision.changes.length}; held: ${held.length}; '
    '${decision.publishes ? 'PUBLISH version ${decision.manifest!['version']}' : 'nothing to publish'}',
  );
  exit(decision.publishes ? 10 : (held.isNotEmpty ? 20 : 0));
}
