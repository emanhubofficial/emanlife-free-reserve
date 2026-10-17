# EmanLife Free Reserve catalogue (publishing only)

This repository publishes two signed static files for the EmanLife app, over HTTPS:

- `site/manifest.json` and `site/manifest.json.sig`

It holds **no application or agent code**. The app accepts a catalogue only if the Ed25519 signature
verifies against a key compiled into the app, the file passes the app's strict validation, and its
version is above the one the phone holds. A file that fails any of that is ignored and the phone keeps
the last catalogue it trusted.

## What runs, and what it costs

`maintain-catalogue` runs daily (and on demand). It reads each provider's own **public, keyless**
pages and model lists (6 GET requests: OpenRouter and NVIDIA model lists, Google's models and
pricing pages, Z.ai's pricing page, Agnes's model page). No account, no API key, no inference: it
cannot spend anything. There is no server, database or research loop.

## The conservative policy

| Situation | What happens |
|---|---|
| A source cannot be read, or its list is under half the size of the last good one | Nothing. It says nothing about any model. |
| A model is absent, or listed but not priced at zero, once | Recorded only. |
| ...on three separate daily checks over at least two days | Retired automatically, with the reason, evidence dates and source. |
| Confirmed, evidence under 45 days old | Nothing, and **no new version** is made. |
| Confirmed, evidence 45 days or older | Evidence date renewed (a new version). |
| A retired model is listed again | **Held** for a person after three good checks; never restored automatically. |
| A newly listed free model | **Held**; never added automatically (privacy, tools, context and terms need a person). |
| A context size that differs from the record | **Held**. |
| A model with no keyless source (Alibaba Qwen) whose evidence is 100 days old | **Held** (the app stops trusting evidence at 120 days). |

The access class (free, free-tier, trial, promotional), the account and API-key requirements and the
privacy wording belong to the owner and are never edited by the schedule. Held items are listed in
one open issue (`catalogue-review`). Every run's decision is kept in `evidence/` (the last 90).

## Signing and its protection

- The scheduled job signs with a **dedicated, limited-purpose key**, `emanlife-reserve-ci-1`, held only
  as the secret `RESERVE_SIGNING_KEY` of the protected environment `publish`. It is read from the
  environment in one step, never written to disk or printed.
- The owner's offline key `emanlife-reserve-1` is **not** here and never should be.
- The workflow has no `pull_request` trigger, grants no permissions by default, pins every action to a
  commit, and runs only from `main`. The environment `publish` is restricted to `main`.
- A catalogue can state only facts about models. It cannot carry a credential (refused before signing),
  an address to call or an action; the app's validator allows known fields only.
- Before anything is replaced, `verify.dart` checks the new file the way a phone would: trusted signature,
  rising version, known fields only, no credential-shaped value, context floor, https evidence.

### If the CI key is ever exposed (rotation)

1. Generate a new key (`dart run tool/reserve/keygen.dart emanlife-reserve-ci-2 <private dir>` in the app repo).
2. Add its public key to the app's `ReserveTrust.keys` and to `trusted_keys.json` here; ship an app release.
3. Replace the secret and the key id in `maintain.yml`; delete the old secret.
4. Ship a release without `emanlife-reserve-ci-1`. Phones then refuse everything it signed, and fall back
   to the last catalogue signed by a key they still trust or to the built-in list.

## One-time setup (owner)

Short version: `gh auth login`, then `tool/reserve/publisher/setup.sh <repository name>` from the EmanLife-AI repository does steps 1 to 6 below. By hand:

1. Create the repository (public, so Pages is free) and push this directory.
2. Settings, Pages: source **GitHub Actions**.
3. Settings, Environments: create `publish`, deployment branches **main only**, no reviewers (it must run unattended); add the secret `RESERVE_SIGNING_KEY` (the base64 seed of `emanlife-reserve-ci-1`).
4. Settings, Branches: protect `main` (no force pushes; only the owner may push).
5. Create the label `catalogue-review`.
6. Run `publish-site` once to publish the first catalogue, then `maintain-catalogue` with *dry run* to see its report.
7. Put `https://<owner>.github.io/<repository>/manifest.json` in the app's `ReserveTrust.productionManifestUrl` and ship a release.
