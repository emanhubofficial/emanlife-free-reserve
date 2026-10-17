// The publishing policy for the free-reserve catalogue, as pure functions of what was observed.
// No network, no clock and no file access, so every rule is tested. The conservative policy:
//
//  * A model is retired only after it has been absent (or listed as not free) on three separate
//    daily checks spanning at least two days, from a source that was read successfully each time.
//    One failed request, one unreachable page or one shortened list changes nothing.
//  * Evidence dates are renewed only when a model is confirmed and its date is older than 45 days,
//    so a quiet catalogue is not re-versioned every day. Nothing else changes without evidence.
//  * Anything ambiguous is HELD for a person: a retired model that reappears, a model whose context
//    changed, a model that can no longer be confirmed and whose evidence is nearly expired, and every
//    newly listed free model. None of it is published automatically.
//  * The access class (free, free-tier, trial, promotional), the account and key requirements and
//    the privacy wording belong to the owner. This policy never edits them.
//  * A new version is produced only when something was published; otherwise there is none.
import 'dart:convert';

import 'reserve_sources.dart';

class Policy {
  const Policy({
    this.retireAfterRuns = 3,
    this.retireAfterDays = 2,
    this.refreshAfterDays = 45,
    this.nearExpiryDays = 100,
    this.reappearRuns = 3,
  });
  final int retireAfterRuns;
  final int retireAfterDays;
  final int refreshAfterDays;
  final int nearExpiryDays;
  final int reappearRuns;
}

class Change {
  const Change(this.kind, this.key, this.detail);
  final String kind; // retire | refresh_evidence
  final String key;
  final String detail;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'model': key,
    'detail': detail,
  };
}

class Held {
  const Held(this.kind, this.key, this.detail);
  final String
  kind; // reappeared | context_changed | needs_review | new_free_model
  final String key;
  final String detail;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'model': key,
    'detail': detail,
  };
}

class Decision {
  Decision(this.manifest, this.state, this.changes, this.held);

  /// The next manifest, or null when nothing was published (so no new version exists).
  final Map<String, dynamic>? manifest;
  final Map<String, dynamic> state;
  final List<Change> changes;
  final List<Held> held;
  bool get publishes => manifest != null;
}

int daysBetween(String from, String to) =>
    DateTime.parse(to).difference(DateTime.parse(from)).inDays;

Map<String, dynamic> _copy(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

Decision decide({
  required Map<String, dynamic> manifest,
  required Map<String, dynamic> state,
  required Map<String, Observation> observations,
  required List<Map<String, Object?>> candidates,
  required String today,
  Policy policy = const Policy(),
}) {
  final next = _copy(manifest);
  final nextState = _copy(state);
  final perModel =
      (nextState['models'] ??= <String, dynamic>{}) as Map<String, dynamic>;
  final changes = <Change>[];
  final held = <Held>[];
  final models = (next['models'] as List).cast<Map<String, dynamic>>();

  for (final m in models) {
    final key = '${m['provider']}/${m['model']}';
    final o = observations[key];
    if (o == null) continue;
    final evidence = m['evidence'] as Map<String, dynamic>;
    final s = (perModel[key] ??= <String, dynamic>{}) as Map<String, dynamic>;
    final isNewDay = s['last_run'] != today;
    final retired = m['status'] == 'retired';

    switch (o.seen) {
      case Seen.unreachable:
        break; // says nothing about the model
      case Seen.manual:
        if (daysBetween(evidence['verified_on'] as String, today) >=
            policy.nearExpiryDays) {
          held.add(
            Held(
              'needs_review',
              key,
              'cannot be checked automatically and its evidence is ${daysBetween(evidence['verified_on'] as String, today)} days old',
            ),
          );
        }
      case Seen.confirmed:
        if (isNewDay) {
          s['confirmed_streak'] = ((s['confirmed_streak'] ?? 0) as int) + 1;
        }
        s['absent'] = 0;
        s['not_free'] = 0;
        s.remove('first_bad');
        if (retired) {
          if ((s['confirmed_streak'] as int) >= policy.reappearRuns) {
            held.add(
              Held(
                'reappeared',
                key,
                'listed again on ${s['confirmed_streak']} consecutive checks; a person decides whether to restore it',
              ),
            );
          }
        } else if (daysBetween(evidence['verified_on'] as String, today) >=
            policy.refreshAfterDays) {
          evidence['verified_on'] = today;
          changes.add(Change('refresh_evidence', key, o.note));
        }
      case Seen.absent || Seen.notFree:
        final field = o.seen == Seen.absent ? 'absent' : 'not_free';
        if (isNewDay) {
          s[field] = ((s[field] ?? 0) as int) + 1;
          s['first_bad'] ??= today;
          s['confirmed_streak'] = 0;
        }
        final runs = (s[field] ?? 0) as int;
        final span = s['first_bad'] == null
            ? 0
            : daysBetween(s['first_bad'] as String, today);
        if (!retired &&
            runs >= policy.retireAfterRuns &&
            span >= policy.retireAfterDays) {
          m['status'] = 'retired';
          m['status_note'] =
              'Checked $today: ${o.note}, on $runs separate daily checks since ${s['first_bad']}. Source: ${o.source}';
          changes.add(
            Change('retire', key, '${o.note} ($runs checks over $span days)'),
          );
        }
    }
    if (o.seen != Seen.unreachable) s['last_run'] = today;
  }

  // A listed context that no longer matches is a change a person should look at.
  for (final c in candidates) {
    held.add(
      Held(
        'new_free_model',
        '${c['provider']}/${c['model']}',
        'newly listed as free (context ${c['context']}); never added automatically',
      ),
    );
  }

  if (changes.isEmpty) {
    return Decision(null, nextState, changes, held);
  }
  next['version'] = (manifest['version'] as int) + 1;
  next['issued_on'] = today;
  return Decision(next, nextState, changes, held);
}
