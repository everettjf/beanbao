# BeanBao website

This directory is the static GitHub Pages site. It uses plain HTML, CSS, and
JavaScript, so there is no build step or package manager. English is the default
at `/`; Simplified Chinese is available at `/zh-CN/`. Each page links to the
other language, and the install steps must stay aligned.

Preview locally from the repository root:

```sh
python3 -m http.server 8000 --directory web
```

Then open `http://localhost:8000/`. The site is a product and installation
guide for the current RootHide developer preview. Its install steps
must stay in sync with [`docs/install-and-configure.md`](../docs/install-and-configure.md)
and the release archive's `INSTALL.md`.

## GitHub Pages

The workflow in [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)
uploads this directory and deploys it from `main`. It skips deployment while
the repository is private, because a Pages site can be publicly reachable even
when its source repository is private. The public site uses **GitHub Actions**
as its Pages build source. Run the workflow if a new push does not trigger it.
The expected URL is
`https://everettjf.github.io/beanbao/`.

See [GitHub's custom workflow instructions](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
for the current Pages settings and permission requirements.
