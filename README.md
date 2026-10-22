# Website

This website is built using [Docusaurus](https://docusaurus.io/), a modern static website generator.

## Quirks of working with Weblate

The source for the documentation is located in the `docs/` folder. The `i18n` folder's content is written by our [Weblate instance](https://translate.readycode.io).

There are a few things to watch out for when writing docs so that they play well with Weblate:

### Code is not translated

Code blocks and their metadata is not detected by Weblate, so if you write something like this:

~~~text
```csharp title="Minimal system example"
public class MySystem : ModSystemBase
{
    protected override void OnUpdate(UpdateTick tick)
    {
        // do something every frame
    }
}
```
~~~

You must manually translate it in the files copied to other locales:

~~~text
```csharp title="最简系统示例"
public class MySystem : ModSystemBase
{
    protected override void OnUpdate(UpdateTick tick)
    {
        // 每帧执行的操作
    }
}
```
~~~

> [!WARNING]
> Weblate will aggressively try to override the translation with the English version. This is because code blocks, including `title` metadata, are copied verbatim and I haven't found a way to fix that as of yet. When merging from the `weblate` branch to `develop`, make sure not to reverse your manual translations.

### Admonitions

Separate admonition tags from content with a newline, like so:

~~~bash

:::note
                    # this empty line is required
This is a note.
                    # so it this one
:::

~~~

## Local Development

~~~bash
yarn start                  # English
yarn start --locale zh-Hans # Chinese
~~~

This command starts a local development server and opens up a browser window. Most changes are reflected live without having to restart the server.

## Build && serve locally

~~~bash
yarn build
yarn serve                  # English
yarn serve --locale zh-Hans # Chinese
~~~

This command generates static content into the `build` directory and can be served using any static contents hosting service.

## Preview a pull request

Comment `/preview` on a pull request to build its current head and serve it at
`https://doc-<pull request>-<first 7 characters of the sha>.preview.readymod.io`. The address is commented on the
pull request when it is ready, after a few minutes.

- **Team only.** Commenting needs write access to this repository and a place in the `PREVIEW_ALLOWED_USERS`
  variable, which an admin keeps. Anyone else's comment does nothing.
- **Tailnet only.** The address answers on the team tailnet and nowhere else, and your machine needs to trust the
  preview certificate once, the same one the ReadyM server's previews use.
- **Three days.** A preview is deleted by the daily sweep once it is three days old, whether or not the pull request
  is still open. Comment `/clearpreview` to delete a pull request's previews straight away.
- **Read it first.** A preview builds the pull request's code. On a pull request from outside the team, read the
  change before you type `/preview`.

How it is kept safe in a public repository is explained at the top of `.github/workflows/preview.yml`.

## Add a new version

To add a new version for a documentation page, follow this guide: https://docusaurus.io/docs/docs-multi-instance#tagging-new-versions.

Remember, that the `docs:version` command expets the **current** version (one that is getting frozen), not the new one.