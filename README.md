# CIStatus

A tiny macOS menu bar utility for checking the latest GitHub Actions runs for one repository.

## License

MIT. See [LICENSE](LICENSE).

## Run

```sh
swift run CIStatus
```

Enter a repository as `owner/repo` in the menu bar popover. The app refreshes once a minute and uses either:

- `GITHUB_TOKEN`, if present
- `gh auth token`, if the GitHub CLI is logged in
- unauthenticated GitHub API access for public repositories

## Notes

- The menu bar title shows the latest run: `CI OK`, `CI Failed`, `CI Running`, or `CI Queued`.
- The popover shows the five most recent workflow runs.
- Settings are stored in macOS app storage, so the chosen repository persists between launches.

## Build a Mac app

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/CIStatus.app
```

The generated app is an agent app (`LSUIElement`), so it lives in the menu bar instead of the Dock.
