# Remote Image Processor API Specification

This specification defines the HTTP API used by Mankai remote image processors. A user adds the server's base URL in **Settings → Image Processing**. Mankai reads the processor metadata, shows the server-defined configuration fields, and sends each reader image to the server when the processor is enabled.

## Table of Contents

- [Endpoints](#endpoints)
- [Processor Information](#processor-information)
  - [`GET /`](#get-)
- [Image Processing](#image-processing)
  - [`POST /process`](#post-process)
- [Authentication (Optional)](#authentication-optional)
  - [`POST /auth/login`](#post-authlogin)
  - [`POST /auth/refresh`](#post-authrefresh)
- [Operational Guidance](#operational-guidance)

## Endpoints

| Method | Path            | Authentication | Purpose                                |
| :----- | :-------------- | :------------- | :------------------------------------- |
| `GET`  | `/`             | Never          | Return processor metadata and config   |
| `POST` | `/process`      | Optional       | Process one image                      |
| `POST` | `/auth/login`   | Never          | Sign in when authentication is enabled |
| `POST` | `/auth/refresh` | Never          | Refresh an access token                |

The URL entered by the user is the base URL. For example, entering `https://images.example.com/mankai` makes the processing endpoint `https://images.example.com/mankai/process`.

## Processor Information

### `GET /`

The metadata endpoint must be available without authentication.

**Response — `200 OK`**

```ts
interface ImageProcessorInfo {
  id: string; // Stable server/processor identifier
  name?: string;
  version?: string;
  description?: string;
  authors?: string[]; // Default: []
  repository?: string;
  authenticationEnabled?: boolean; // Default: false
  configs?: Config[]; // Default: []
}

type ConfigType =
  "text" | "password" | "number" | "slider" | "boolean" | "select" | "color";

interface Config {
  key: string; // Unique within this processor
  name: string; // User-facing label or localization key
  description?: string;
  type: ConfigType;
  defaultValue: string | number | boolean;
  options?: string[]; // Used by "select"
  min?: number; // Used by "slider"
  max?: number; // Used by "slider"
  step?: number; // Used by "slider"
  supportsOpacity?: boolean; // Used by "color", defaults to false
}
```

`color` configs use sRGB hex strings. By default, the picker is opaque and saves uppercase `#RRGGBB` values such as `"#F2E4C9"`. Set `supportsOpacity` to `true` to enable the opacity control and save `#RRGGBBAA` values. The leading `#` is optional on input.

Example:

```json
{
  "id": "com.example.manga-denoise",
  "name": "Manga Denoise",
  "version": "1.0.0",
  "description": "Removes scan noise while preserving line art.",
  "authors": ["Example Lab"],
  "repository": "https://example.com/manga-denoise",
  "authenticationEnabled": false,
  "configs": [
    {
      "key": "strength",
      "name": "Strength",
      "description": "Higher values remove more noise.",
      "type": "slider",
      "defaultValue": 0.5,
      "min": 0,
      "max": 1,
      "step": 0.1
    },
    {
      "key": "preserveText",
      "name": "Preserve text",
      "type": "boolean",
      "defaultValue": true
    }
  ]
}
```

## Image Processing

### `POST /process`

The request uses `multipart/form-data` so the image remains binary. It contains exactly these named parts:

| Part      | Content type       | Value                                     |
| :-------- | :----------------- | :---------------------------------------- |
| `image`   | `image/png`        | The current pipeline image as a PNG file  |
| `configs` | `application/json` | All current server-defined config values  |
| `context` | `application/json` | The reader display size in logical points |

`configs` uses the same key/value shape as the JavaScript plugin configuration API:

```ts
interface ConfigValue {
  key: string;
  value: string | number | boolean;
}

type ConfigValues = ConfigValue[];
```

Example `configs` part:

```json
[
  { "key": "strength", "value": 0.8 },
  { "key": "preserveText", "value": true }
]
```

The context part has this shape:

```ts
interface ProcessContext {
  pointSize: {
    width: number;
    height: number;
  };
}
```

The server must return the processed image directly with a `2xx` status and an `image/*` `Content-Type`. PNG, JPEG, WebP, HEIF, and any other image format supported by the client platform are allowed. The response is passed to the next configured image processor, so the server should preserve useful resolution and quality.

For non-`2xx` responses, a short plain-text or JSON error body may be returned. Mankai treats the processing attempt as failed and keeps the unprocessed reader image available.

## Authentication (Optional)

Set `authenticationEnabled` to `true` to make `POST /process` require JWT bearer authentication. Mankai then shows username and password fields and uses the same token flow as its HTTP plugins.

### `POST /auth/login`

**Request Body**

```json
{
  "username": "user",
  "password": "secret"
}
```

**Response — `200 OK`**

```json
{
  "accessToken": "short-lived JWT",
  "refreshToken": "long-lived refresh token"
}
```

### `POST /auth/refresh`

**Request Body**

```json
{
  "refreshToken": "long-lived refresh token"
}
```

**Response — `200 OK`**

```json
{
  "accessToken": "new short-lived JWT"
}
```

For an authenticated processor, Mankai sends `Authorization: Bearer <accessToken>` with `POST /process`. A `401` or `403` response triggers one token refresh and one retry of the original multipart request. The metadata and `/auth/*` endpoints never require a bearer token.

When `authenticationEnabled` is omitted or `false`, the auth endpoints are not required and Mankai sends `POST /process` without an `Authorization` header.
