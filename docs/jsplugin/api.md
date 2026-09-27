# Mankai JavaScript Plugin Specification

This specification describes the JSON format and JavaScript API for plugins that provide manga from an online source to [Mankai](https://github.com/nohackjustnoobb/mankai).

JavaScript plugins are read-only sources. The app loads the manifest from a URL or from pasted JSON, then executes the callback scripts in a hidden WebKit web view. Install only plugins you trust: a plugin can make network requests and execute arbitrary JavaScript in the app's plugin runtime.

## Table of contents

- [Manifest](#manifest)
  - [Metadata fields](#metadata-fields)
  - [Script format](#script-format)
- [Callback scripts](#callback-scripts)
  - [`isOnline`](#isonline)
  - [`getSuggestion(query)`](#getsuggestionquery)
  - [`search(query, page, genre, status, isAuthor)`](#searchquery-page-genre-status-isauthor)
  - [`getList(page, genre, status)`](#getlistpage-genre-status)
  - [`getMangas(ids)`](#getmangasids)
  - [`getMangaUpdates(mangas)`](#getmangaupdatesmangas)
  - [`getDetailedManga(id)`](#getdetailedmangaid)
  - [`getChapter(manga, chapter)`](#getchaptermanga-chapter)
  - [`getImage(url)`](#getimageurl)
- [Data types](#data-types)
  - [Genres](#genres)
  - [Statuses](#statuses)
  - [Reading directions](#reading-directions)
- [Runtime helpers](#runtime-helpers)
  - [`fetch(url, options)`](#fetchurl-options)
  - [`console.log(...values)`](#consolelogvalues)
  - [`s2t(text)` and `t2s(text)`](#s2ttext-and-t2stext)
  - [`getConfigs()`](#getconfigs)
  - [Persistent storage](#persistent-storage)
- [Configuration](#configuration)
- [Cooldowns](#cooldowns)

## Manifest

The manifest is a JSON object. Only the `id` field is required by the decoder, the callback scripts required by the operations you use must still be supplied.

```ts
type ScriptName =
  | "isOnline"
  | "getSuggestion"
  | "search"
  | "getList"
  | "getMangas"
  | "getMangaUpdates"
  | "getDetailedManga"
  | "getChapter"
  | "getImage";

type PluginCapability =
  | "onlineCheck"
  | "suggestions"
  | "list"
  | "listByGenre"
  | "listByStatus"
  | "search"
  | "searchByGenre"
  | "searchByStatus"
  | "searchByAuthor"
  | "mangaDetails"
  | "batchMangas"
  | "mangaUpdates"
  | "chapter"
  | "image";

interface JsPluginManifest {
  id: string;
  name?: string;
  version?: string;
  description?: string;
  authors?: string[];
  repository?: string;
  updatesUrl?: string;
  availableGenres?: Genre[];
  scripts?: Record<ScriptName, string>;
  configs?: Config[];
  getImageHeaders?: Record<string, string>;
  cooldown?: Cooldown;
  capabilities?: PluginCapability[];
}
```

### Metadata fields

| Field             | Type                     | Description                                                                                                             |
| :---------------- | :----------------------- | :---------------------------------------------------------------------------------------------------------------------- |
| `id`              | `string`                 | Stable, globally unique plugin identifier. It is also used to scope persistent storage.                                 |
| `name`            | `string`                 | Display name. Defaults to the ID when omitted.                                                                          |
| `version`         | `string`                 | Plugin version shown in the app and compared for updates.                                                               |
| `description`     | `string`                 | Short description displayed in plugin settings.                                                                         |
| `authors`         | `string[]`               | Plugin authors. Defaults to `[]`.                                                                                       |
| `repository`      | `string`                 | Source-code or project URL.                                                                                             |
| `updatesUrl`      | `string`                 | URL of a manifest to check for updates.                                                                                 |
| `availableGenres` | `Genre[]`                | Genres supported by the source. Defaults to `[]`.                                                                       |
| `scripts`         | `Record<string, string>` | JavaScript source keyed by the script names below. Unknown keys are ignored.                                            |
| `configs`         | `Config[]`               | User-configurable values exposed to the scripts. Defaults to `[]`.                                                      |
| `getImageHeaders` | `Record<string, string>` | If present, Mankai downloads every image URL with these native request headers and does not call the `getImage` script. |
| `cooldown`        | `Cooldown`               | Optional request throttling and image concurrency limits.                                                               |
| `capabilities`    | `PluginCapability[]`     | Operations supported by the plugin. By default, every capability except `mangaUpdates` is enabled.                      |

### Script format

Every script value is a string containing a function and an export marker:

```js
async function isOnline() {
  const response = await fetch("https://example.com/");
  return response.ok;
}

export { isOnline as default };
```

The marker must use the form `export{functionName as default};`. Mankai removes the marker before execution and calls the named function. Functions may be synchronous or asynchronous. Mankai awaits their result. A script can contain helper functions as well as its exported function.

The manifest parser does not reject a missing script, but invoking a missing callback fails at runtime. A complete plugin normally provides all callbacks listed below, unless it uses `getImageHeaders` instead of `getImage`.

## Callback scripts

The optional `capabilities` field accepts the values listed below. If it is omitted, every capability except `mangaUpdates` is enabled. A plugin can use the field to advertise only the operations it implements, so the app can avoid invoking unsupported callbacks.

```text
onlineCheck, suggestions, list, listByGenre, listByStatus, search, searchByGenre, searchByStatus, searchByAuthor, mangaDetails, batchMangas, mangaUpdates, chapter, image
```

Plugins with either `batchMangas` or `mangaUpdates` can participate in library update checks. Include `mangaUpdates` when the plugin should control which manga are marked as updated through the dedicated `getMangaUpdates` callback. Exclude `mangaUpdates` to use Mankai's default behavior, which calls `getMangas`, refreshes the returned metadata, and compares the returned latest chapters. The default behavior requires `batchMangas`.

The keys and function signatures are:

| Key                | Function signature                             | Return value                                        |
| :----------------- | :--------------------------------------------- | :-------------------------------------------------- |
| `isOnline`         | `isOnline()`                                   | `boolean`                                           |
| `getSuggestion`    | `getSuggestion(query)`                         | `string[]`                                          |
| `search`           | `search(query, page, genre, status, isAuthor)` | `Manga[]`                                           |
| `getList`          | `getList(page, genre, status)`                 | `Manga[]`                                           |
| `getMangas`        | `getMangas(ids)`                               | `Manga[]`                                           |
| `getMangaUpdates`  | `getMangaUpdates(mangas)`                      | `MangaUpdate[]` metadata patches and update flags   |
| `getDetailedManga` | `getDetailedManga(id)`                         | `DetailedManga`                                     |
| `getChapter`       | `getChapter(manga, chapter)`                   | `string[]` of image URLs                            |
| `getImage`         | `getImage(url)`                                | Base64 image data, or an image proxy request object |

Details for each argument and result follow.

### `isOnline`

Return `true` when the source is reachable and usable, otherwise return `false`. Throwing or returning a non-boolean result is treated as a failed plugin call.

### `getSuggestion(query)`

Return an array of strings suitable for search suggestions. The manifest key is singular: `getSuggestion`.

```js
async function getSuggestion(query) {
  const response = await fetch(
    `https://example.com/suggestions?q=${encodeURIComponent(query)}`,
  );
  if (!response.ok) return [];
  return await response.json();
}

export { getSuggestion as default };
```

### `search(query, page, genre, status, isAuthor)`

Search for manga by title or author. `page` is a 1-based page number. `genre` is one of the strings in [Genres](#genres), and `status` is one of the numeric values in [Statuses](#statuses). When `isAuthor` is `true`, search the source's author field instead of its title field. Return lightweight `Manga` objects.

### `getList(page, genre, status)`

Return a paginated list from the source, using the same `page`, `genre`, and `status` arguments as `search`.

### `getMangas(ids)`

Return lightweight manga objects for the requested string IDs. The result may contain fewer entries if the source no longer has some IDs.

### `getMangaUpdates(mangas)`

Each request entry contains a manga ID and the latest chapter currently known by Mankai. This callback lets the plugin control update behavior. Exclude the `mangaUpdates` capability when the plugin should use Mankai's default batch comparison instead.

```ts
interface MangaUpdateRequest {
  id: string;
  latestChapter: Chapter;
}
```

Return a `MangaUpdate[]`. Every result must include `id` and `updates`. The `updates` flag alone controls whether Mankai marks the saved manga as updated, metadata is refreshed for every returned result, including results where `updates` is `false`.

All other properties are patches. Mankai applies only non-null properties to its existing local manga snapshot. Omitted and `null` properties leave the existing value unchanged. `latestChapter` advances the saved update-check baseline only when `updates` is `true`. Results omitted from the response are left unchanged.

```ts
interface MangaUpdate extends Manga {
  updates: boolean;
}
```

```js
async function getMangaUpdates(mangas) {
  const response = await fetch("https://example.com/manga/updates", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mangas),
  });
  if (!response.ok) return [];
  return await response.json();
}

export { getMangaUpdates as default };
```

For example, a plugin can return `{ id: "completed-series", updates: false, status: 2 }` to refresh the status without showing an unread update.

### `getDetailedManga(id)`

Return a full `DetailedManga` object. Mankai serializes the returned value to JSON before decoding it, so return a JavaScript object rather than a JSON string.

### `getChapter(manga, chapter)`

Return the ordered image URLs for `chapter`. The `manga` argument is the full object returned by `getDetailedManga`, and `chapter` is the selected chapter object. Image URLs should be absolute URLs because Mankai later passes each one to `getImage`.

```js
async function getChapter(manga, chapter) {
  const response = await fetch(
    `https://example.com/manga/${encodeURIComponent(manga.id)}/chapter/${encodeURIComponent(chapter.id)}`,
  );
  if (!response.ok) return [];
  return await response.json();
}

export { getChapter as default };
```

### `getImage(url)`

When `getImageHeaders` is not present, Mankai calls this script for covers and chapter pages. It accepts either of these results:

1. A base64-encoded string containing the raw image bytes. Do not include a `data:image/...;base64,` prefix.
2. An object that tells Mankai to make a native request:

   ```ts
   interface ImageProxyRequest {
     url: string;
     headers: Record<string, string>;
   }
   ```

For example:

```js
async function getImage(url) {
  return {
    url,
    headers: {
      Referer: "https://example.com/",
      "User-Agent": "Mozilla/5.0",
    },
  };
}

export { getImage as default };
```

If the manifest contains `getImageHeaders`, the equivalent native request is made automatically for every image URL:

```json
{
  "getImageHeaders": {
    "Referer": "https://example.com/",
    "User-Agent": "Mozilla/5.0"
  }
}
```

This mode takes precedence over the `getImage` script. The headers apply to covers and chapter pages alike.

## Data types

The following shapes are accepted by the callback results. Optional properties may be omitted.

```ts
interface Chapter {
  id: string;
  title?: string;
  locked?: boolean;
}

interface Manga {
  id: string;
  title?: string;
  cover?: string;
  status?: Status;
  latestChapter?: Chapter;
  meta?: string;
}

interface ChapterGroup {
  id?: string;
  title: string;
  chapters: Chapter[];
}

interface DetailedManga {
  id: string;
  title?: string;
  cover?: string;
  status?: Status;
  readingDirection?: ReadingDirection;
  latestChapter?: Chapter;
  description?: string;
  externalLink?: string;
  updatedAt?: number; // Unix timestamp in milliseconds
  authors?: string[];
  genres?: Genre[];
  chapters?: ChapterGroup[];
  remarks?: string;
  meta?: string;
}
```

`authors`, `genres`, and `chapters` default to empty arrays when omitted from a detailed manga.

### Genres

The string values recognized by Mankai are:

```text
all, action, romance, yuri, boysLove, otokonoko, schoolLife, adventure,
harem, speculativeFiction, war, suspense, fanFiction, comedy, magic, horror,
historical, sports, mature, mecha
```

### Statuses

| Name        | Value |
| :---------- | :---- |
| `any`       | `0`   |
| `onGoing`   | `1`   |
| `completed` | `2`   |

### Reading directions

| Name          | Value |
| :------------ | :---- |
| `leftToRight` | `1`   |
| `rightToLeft` | `2`   |
| `vertical`    | `3`   |

## Runtime helpers

Mankai injects the following helpers into every callback script.

### `fetch(url, options)`

The runtime provides a native-network `fetch` implementation. It supports the following request options:

```ts
interface FetchOptions {
  method?: string; // Defaults to "GET"
  headers?: Record<string, string> | Headers;
  body?: string;
}
```

The returned response has these properties and methods:

```ts
interface FetchResponse {
  ok: boolean;
  status: number;
  statusText: string;
  url: string;
  headers: Headers;
  text(): Promise<string>;
  json(): Promise<any>;
  blob(): Promise<Blob>;
  arrayBuffer(): Promise<ArrayBuffer>;
}
```

Non-2xx responses resolve normally with `ok === false`, use `ok` or `status` to handle them. Network and invalid-URL failures reject. Request and response bodies are transferred through the native bridge, so use `arrayBuffer()` when the response is binary.

### `console.log(...values)`

`console.log` is redirected to Mankai's JavaScript plugin log. It is useful for diagnosing a plugin during development:

```js
console.log("searching", query);
```

### `s2t(text)` and `t2s(text)`

These asynchronous helpers convert Chinese text using OpenCC:

```js
const traditional = await s2t("简体转繁体");
const simplified = await t2s("繁體轉簡體");
```

`s2t` converts simplified Chinese to traditional Chinese, while `t2s` does the reverse.

### `getConfigs()`

Returns the current values for the manifest's declared configs as an array:

```ts
interface ConfigValue {
  key: string;
  value: unknown;
}
```

Example:

```js
function configValue(key) {
  return getConfigs().find((config) => config.key === key)?.value;
}

const username = configValue("username");
```

### Persistent storage

These helpers store string values in a key-value store scoped to the plugin's `id`:

```ts
getValue(key: string): Promise<string | null>;
setValue(key: string, value: string): Promise<void>;
removeValue(key: string): Promise<boolean>;
```

Use `await` with all three helpers. Values survive app restarts and plugin updates, and are removed when the plugin is deleted.

```js
const token = await getValue("token");
if (!token) {
  await setValue("token", "new-token");
}
await removeValue("temporary-value");
```

## Configuration

A config entry has this shape:

```ts
interface Config {
  key: string;
  name: string;
  description?: string;
  type: "text" | "password" | "number" | "slider" | "boolean" | "select";
  defaultValue: unknown;
  options?: string[];
  min?: number;
  max?: number;
  step?: number;
}
```

`options` is used for `select` configs. `min`, `max`, and `step` configure the range and increment for `slider` configs. The app initializes each config with `defaultValue`, persists changes made in plugin settings, and exposes the current values through `getConfigs()`.

Example:

```json
{
  "configs": [
    {
      "key": "language",
      "name": "Language",
      "description": "Language used when requesting titles.",
      "type": "select",
      "defaultValue": "en",
      "options": ["en", "zh-Hans", "zh-Hant"]
    },
    {
      "key": "imageQuality",
      "name": "Image quality",
      "type": "slider",
      "defaultValue": 80,
      "min": 10,
      "max": 100,
      "step": 5
    },
    {
      "key": "includeMature",
      "name": "Include mature content",
      "type": "boolean",
      "defaultValue": false
    }
  ]
}
```

When a plugin is imported from a URL, matching query parameters override the declared defaults. Values are parsed according to `type`: booleans recognize `true` and `1`, numbers and sliders parse as integers or decimals, and text/password/select values remain strings after surrounding whitespace is trimmed.

## Cooldowns

Cooldown values are in milliseconds:

```ts
interface Cooldown {
  default?: number;
  getImage?: number;
  getImageConcurrency?: number;
}
```

| Field                 | Description                                                                                       |
| :-------------------- | :------------------------------------------------------------------------------------------------ |
| `default`             | Minimum spacing between non-image operations such as search, list, details, and chapter requests. |
| `getImage`            | Minimum spacing between image requests. Images use a separate schedule from other operations.     |
| `getImageConcurrency` | Maximum number of image requests in flight at once. Values less than `1` do not set a limit.      |

Use these fields to respect the source's rate limits. For example:

```json
{
  "cooldown": {
    "default": 500,
    "getImage": 100,
    "getImageConcurrency": 2
  }
}
```
