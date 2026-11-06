# Maintaining this fork

This fork carries a few extra settings and fixes on top of upstream Gale. Everything else is upstream's, so the recurring job is **syncing upstream** and **cutting a release**.

`origin` is this fork (`Niko666233/gale`), `upstream` is `https://github.com/Kesomannen/gale.git`.

## Syncing upstream

```bash
git fetch upstream --tags
git merge upstream/master
```

Check the fork still builds before doing anything else:

```bash
pnpm install                 # upstream may have changed dependencies
pnpm run locale:compile      # upstream may have added message keys
pnpm run check
pnpm run build
cd src-tauri && cargo check && cd ..
```

### Conflicts

They are almost always in the same places:

| File                                                                | What to do                                                                                                                         |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `package.json`, `src-tauri/Cargo.toml`, `src-tauri/tauri.conf.json` | take upstream's version but append the fork revision: `1.23.3` → `1.23.3-1`. `src-tauri/Cargo.lock` fixes itself on the next build |
| `CHANGELOG.md`                                                      | keep upstream's new entries, keep this fork's older entries below them, add a new fork entry on top                                |
| `src/lib/types.ts`, `messages/en.json`, `src/routes/+layout.svelte` | usually auto-merges — just confirm `hideReadmeH1`, `useSystemProxy` and the `prefsStore` import survived                           |
| anything else                                                       | take upstream's side unless it is one of the fork changes below                                                                    |

### What the fork actually changes

Everything not listed here should stay identical to upstream:

1. `src/lib/components/mod-list/ModDetails.svelte` — `formatReadme()` only strips `# ` lines when the preference is on.
2. `src-tauri/src/prefs/mod.rs` — `hide_readme_h1` / `use_system_proxy` / `pin_dependency_versions` fields, their defaults, and the client rebuild in `Prefs::set`.
   `pin_dependency_versions` is threaded into `Thunderstore::dependencies(deps, pin_versions)` in `src-tauri/src/thunderstore/mod.rs`; everything else about dependency resolution is upstream's.
3. `src-tauri/src/state.rs` — `RwLock<ClientWithMiddleware>`, `.no_proxy()` when the preference is off.
4. `src/lib/state/prefs.svelte.ts` — app-wide preferences store, loaded in `src/routes/+layout.svelte`.
5. `src/routes/prefs/+page.svelte` — the toggles.
6. `src-tauri/tauri.conf.json` — fork updater public key and endpoint.
7. `vite.config.ts` — `server.watch.ignored: ['**/src-tauri/**']` (Windows `EBUSY` when cargo holds `target/`).
8. `src-tauri/src/config/bepinex/de.rs` — the "Acceptable value range: From X to Y in increments of Z" line only keeps `X` and `Y`; upstream tries to parse `"500 in increments of 50"` as the maximum and errors out. Covered by `check_range_with_increments` in `config/bepinex/tests.rs`.
9. `src-tauri/src/config/commands.rs` (`get_config_text` / `set_config_text`), `src/lib/api/config.ts`, `src/lib/components/config/ConfigTextEditor.svelte` and `src/routes/config/+page.svelte` — plain-text editing for unsupported or unparsable config files. Both commands refuse any path that is not in the profile's config cache.
10. `README.md` / `CHANGELOG.md` — fork section and AI disclosure.

After a merge, smoke-test with `pnpm tauri dev`: a mod readme starting with `# Heading` must show it, toggling the system proxy must still save, and a config file must still open.

## Cutting a release

Version rules:

- The app version must be **numeric**: `1.23.3` or `1.23.3-1`. The WiX/MSI bundler rejects `1.23.3-fork.1`, so the fork wording lives on the tag (`v1.23.3-fork.1`).
- It must be **greater** than the installed version for the updater to offer it. `1.23.3-1` sorts _below_ `1.23.3` in semver, which is why the fork revision is always appended to the upstream version being merged.
- The part before the dash is always upstream's version — never raise it for a fork-only change. Bump the revision instead (`1.23.3-3` → `1.23.3-4`); when a new upstream version is merged, reset it (`1.24.0` → `1.24.0-1`).

One command does the rest:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fork-release.ps1 -Version 1.23.3-1 -Tag v1.23.3-fork.1
```

It writes the version into the three files, builds the MSI, signs it, writes `latest.json`, creates the GitHub release, then verifies the published assets and the updater endpoint. Add `-SkipBuild` to reuse an MSI that is already in `src-tauri/target/release/bundle/msi`.

### Notes and traps

- The signing key is **not** in the repository: `%USERPROFILE%\Desktop\Work\gale-release-key\gale-updater.key`. Back it up — losing it means future updates cannot be signed and everyone has to reinstall by hand.
- Never publish a draft or pre-release: the endpoint baked into the app, `/releases/latest/download/latest.json`, only resolves to a normal release.
- If the build hangs on `Info Decrypting updater signing key, expect a prompt for password`, the password variable never reached the CLI. Kill it, sign the already-built MSI with `pnpm exec tauri signer sign -f <key> -p "" <msi>`, then rerun the script with `-SkipBuild`.
- The script refuses versions that are not MSI-compatible, so a bad version fails in seconds instead of an hour into a build.

## Not automated

- Resolving merge conflicts.
- Testing the app before publishing.
- CI: the upstream `.github` directory is deleted in this fork on purpose.
