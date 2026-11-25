# DevMate

Development and Projects tabs for macOS apps, as a Swift package. GitHub and
Azure DevOps sit behind small capability protocols, and the UI shows what each
provider declares.

| Product | Holds |
| --- | --- |
| `DevMateCore` | Models, provider capabilities, the repo registry and lane safety |
| `DevMateGit` | The local Git engine: status, staging, commits, branches, history, diffs, stash and sync |
| `DevMateGitHub` | The GitHub provider, over the `gh` command |
| `DevMateAzure` | The Azure DevOps provider |
| `DevMateUI` | The Development and Projects views |

DevMate has no dependency on any terminal or agent package. An app adapts it to
its own lane store.

## Using it

Pin a revision of `main`:

```swift
.package(url: "https://github.com/focusedsystems/devmate.git", revision: "<commit>")
```

To follow `main`, copy `templates/devmate-sync.yml` to the app's
`.github/workflows/` and set `APP_PRODUCT`. It moves the pin only after the app
builds and its tests pass against the new revision.

## Projects

`ProjectsView` is the filter row, a sortable table, a board and a detail pane.
It talks only to a `ProjectsProvider`, which says what things are called and
which features exist, so a provider without saved queries shows no Queries view.

```swift
let model = ProjectsModel(
    provider: GitHubProjectsProvider(gh: GitHubCLI(owner: "example")),
    configuration: ProjectsConfiguration(
        containers: ["app", "docs"],
        cache: DiskCache(namespace: "com.example.app"),
        lanePolicy: LanePromptPolicy(owner: "example")
    )
)
model.onOpenLane = { request in /* paste request.prompt into a lane */ }
```

Dragging a card between columns needs the app to declare the card type in its
`Info.plist`, under `UTExportedTypeDeclarations`: identifier
`systems.focused.devmate.work-card`, conforming to `public.data`.

## Development

`DevelopmentView` is Repos, Pulls, Commits, Pipelines and Skills. It lists the
repositories in the registry and shows the segments its provider declares.

```swift
let model = DevelopmentModel(
    provider: GitHubDevelopmentProvider(defaultOwner: "example"),
    source: RegistryRepoSource(bundleID: "com.example.app", fallback: catalog),
    cache: DiskCache(namespace: "com.example.app")
)
model.onOpenCheckout = { repo, request, worktree in /* open a plain shell lane */ }
```

Repos is a full Git client. Anything that changes or discards work asks first,
and nothing force-pushes. Apps add their own menu items and detail views through
`RepoWorkspaceSlots` and `DevelopmentSlots`.

The Repos sidebar's Custom Order is the person's own order once they drag a row
or use Move Up or Move Down, saved per app. Until then it is the app's order, if
it gives one, then by name. An app passes its order as checkout paths, and can
change it later:

```swift
model.repos.preferredOrder = ["~/Developer/app", "~/Developer/docs"]
```

An app can withhold folders by name with `RepoWorkspaceSlots.withheld`. Git is told
to exclude them, so a withheld file is never listed, shown, searched, counted,
stashed or committed from the app. A host's diff that cannot be read with
certainty is held back whole.

## Run view

Opening a run in Pipelines shows its stages, jobs and steps in a sidebar and
the selected one's log beside it, as the host's web page does. The sidebar is a
native outline: stages are headers, jobs disclose their steps, a step that has
not run shows a hollow circle, and the row holding an approval says "waiting".
The log has line numbers, ANSI and `##[section]`, `##[command]`, `##[warning]`
and `##[error]` colouring, groups that collapse, clickable addresses, the
system find bar, and follows a running step. Left and Right collapse and expand,
Command-[ and Command-] go back and forward.

A provider that can show this returns a `RunDetailProvider` from
`runDetail(for:in:)`. `AzureRunDetail` reads a build over the REST API with a
token the app supplies; `AzureCLITokens` is one that asks the person's `az`.
`GitHubRunDetail` reads a workflow run through a transport the app supplies, or
through `gh`. An app can also show the run view on its own, under its own
header:

```swift
let model = RunDetailModel(
    provider: AzureRunDetail(organization: "example", project: "app", buildID: 1, token: { try await signIn.token() }),
    runName: "Build 1"
)
RunDetailView(model: model) { MyRunHeader() }
```

Add `RunDetailCommands()` to the app's commands so every action is in a menu.
A waiting approval shows `RunApprovalCard`; answering it writes to the live
run, so the card asks first.

`swift run RunDetailSnapshot <folder>` draws the view from made-up fixtures
and writes PNGs, without opening a window.

## Checks

The zone check looks for private detail in tracked files, commit messages and
pull request text:

```bash
python3 scripts/zone_check.py
```

## License

MIT, except the parts derived from Apache-2.0 code listed in
`THIRD_PARTY_NOTICES.md`.
