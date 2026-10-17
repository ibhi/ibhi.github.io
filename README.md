# ibhi.github.io

Source for my blog at **https://ibhi.github.io** — technical write-ups on AI agents, authentication, and containers.

Built with [Hugo](https://gohugo.io/) and the [Blowfish](https://blowfish.page/) theme, deployed to [GitHub Pages](https://pages.github.com/) via GitHub Actions.

## Local preview

Everything runs in [Podman](https://podman.io/) containers — no Hugo, Dart Sass or Node.js needed on the host:

```bash
./preview.sh preview   # production build (same flags as CI) on http://localhost:8080 — no drafts
./preview.sh dev       # live-reloading server on http://localhost:1313 — drafts included
./preview.sh stop      # stop the preview containers
./preview.sh shell     # shell with hugo available, repo mounted at /site
```

The image pins the same tool versions as the deploy workflow, so the local preview matches what will be published.

## Deploy

Pushing to `main` triggers the workflow in [`.github/workflows/hugo.yaml`](.github/workflows/hugo.yaml), which builds the site (`hugo --gc --minify`) and deploys it to GitHub Pages.

## Layout

| Path | Purpose |
| --- | --- |
| `content/posts/` | Blog posts |
| `assets/images/` | Post images |
| `config/_default/` | Hugo configuration |
| `layouts/` | Theme overrides and custom shortcodes |
| `themes/blowfish/` | Theme (git submodule — see below) |
| `Containerfile`, `preview.sh` | Local preview tooling |

## Cloning

The theme is a git submodule, so clone with:

```bash
git clone --recurse-submodules https://github.com/ibhi/ibhi.github.io.git
```
