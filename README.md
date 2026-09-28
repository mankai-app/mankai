> [!IMPORTANT]
> Mankai does not provide, host, or distribute any media content. Users are responsible for obtaining media through legal means and complying with their local laws. Any plugins used with the app are unaffiliated with Mankai, and we have no control over them.

> [!WARNING]
> Mankai is pre-1.0.0, and breaking changes may be introduced before the 1.0.0 release. See the [roadmap](#road-to-100) for planned milestones.

<div align="center">

<img src="assets/icon.png" width="128" />

# Mankai

<!-- [![Swift](https://img.shields.io/badge/swift-F54A2A?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/swift/) -->

[![GitHub License](https://img.shields.io/github/license/mankai-app/mankai?style=for-the-badge)](https://github.com/mankai-app/mankai/blob/master/LICENSE)
[![Version](https://img.shields.io/github/v/tag/mankai-app/mankai?style=for-the-badge&label=version)](https://github.com/mankai-app/mankai/tags)
[![Supported iOS/iPadOS](https://img.shields.io/badge/iOS%2FiPadOS-17.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![Supported macOS](https://img.shields.io/badge/macOS%20Catalyst-14.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/mac-catalyst/)

</div>

Mankai is a powerful, extensible manga reader and manager for iOS, iPadOS, and macOS via Mac Catalyst. It supports iOS and iPadOS 17.0+ and macOS 14.0+, and is primarily built with SwiftUI, featuring a high-performance UIKit-based reader, multi-source plugin support, and cross-device syncing.

![Demo](assets/demo.png)

<details>
<summary>More Screenshots</summary>

### iPhone

|              Home               |                Library                |                Details                |
| :-----------------------------: | :-----------------------------------: | :-----------------------------------: |
| ![Home](assets/iphone-home.png) | ![Library](assets/iphone-library.png) | ![Details](assets/iphone-details.png) |

|                History                |                 Downloads                 |               Reader                |
| :-----------------------------------: | :---------------------------------------: | :---------------------------------: |
| ![History](assets/iphone-history.png) | ![Downloads](assets/iphone-downloads.png) | ![Reader](assets/iphone-reader.png) |

### iPad

|             Home              |               Library               |               Details               |
| :---------------------------: | :---------------------------------: | :---------------------------------: |
| ![Home](assets/ipad-home.png) | ![Library](assets/ipad-library.png) | ![Details](assets/ipad-details.png) |

|               History               |                Downloads                |              Reader               |
| :---------------------------------: | :-------------------------------------: | :-------------------------------: |
| ![History](assets/ipad-history.png) | ![Downloads](assets/ipad-downloads.png) | ![Reader](assets/ipad-reader.png) |

</details>

## Features

- **Extensible Plugin System**: Support for [JavaScript, File System, and HTTP](#plugins) sources.
- **Local and Network Collections**: Read [CBZ, CBR, EPUB, and PDF files](#parsers) from local folders, [remote shares, or OPDS catalogs](#remote-sources).
- **Modern UI**: A responsive interface built with SwiftUI.
- **High-Performance Readers**: [Continuous and Paged](#reader) reading modes built on UIKit.
- **Smart Grouping**: Deep learning-powered [automatic spread detection](#smart-grouping).
- **On-Device AI Upscaling**: Sharpen low-resolution pages with optional [4× Real-ESRGAN upscaling](#real-esrgan-upscaling).
- **Library & History**: Manage your collection and track reading progress.
- **Cross-Device Syncing**: Keep your library in sync using [HttpEngine or Supabase](#syncing).
- **Download Manager**: Save manga chapters for offline access.
- **Remote Image Processing**: Send reader images to configurable HTTP processors, with optional JWT authentication.

## Road to 1.0.0

### App Features

- [x] **Plugin Installation Deep Links** - Review and add one or more plugins through a deep link.
- [ ] **Export** - Export content from Mankai.
- [ ] ~~**Sharing** - Share manga as an image.~~
- [x] **Page curl animations** - Choose realistic page-turning animations in the paged reader for a more immersive reading experience.
- [ ] ~~**NavigationTransition (Hero Animation)** - Add smooth hero animations between related views.~~

### Sync Engines

- [ ] **iCloud** - Pending availability of resources (aka. I have no money)

### Integrations

- [ ] **Komga** - Support for the Komga API.
- [x] **OPDS 1.2** - Open Publication Distribution System catalog support.
- [x] **SMB** - Server Message Block support.
- [x] **WebDAV** - Web Distributed Authoring and Versioning support.
- [x] **NFS** - Network File System support.
- [ ] **FTP** - File Transfer Protocol support.
- [x] **SFTP** - SSH File Transfer Protocol support.

### Parsers

- [x] **EPUB** - Digital book format.
- [x] **PDF** - Portable Document Format.
- [x] **CBR** - Comic Book RAR archive.
- [ ] **Mankai Custom Format** - A dedicated format tailored to Mankai's needs.

### AI Features

- [x] **AI Upscaling** - Enhance low-resolution pages for a sharper reading experience.
- [ ] **Smart Dark Mode** - Transform page images into dark-friendly versions with AI while preserving readable line art, contrast, and important details.

## Plugins

Mankai is designed to be extensible. It supports three types of plugins, each serving a distinct function:

### JavaScript Plugin (JsPlugin)

This plugin scrapes content from third-party manga websites, allowing you to browse and read manga from various online aggregators directly within the app.

- **Documentation**: [JavaScript Plugin API](docs/jsplugin/api.md)
- **Examples**: [plugins](https://github.com/mankai-app/plugins)

### File System Plugin (FsPlugin)

This plugin manages manga stored as local files stored on your device or a connected service.

### Http Plugin (HttpPlugin)

This plugin is designed for external providers to use Mankai as a reader and, optionally, an editor. It connects to servers implementing the standard API and supports authentication.

- **Specification**: [Mankai API Specification](docs/httpplugin/api.md) (see also the [Mankai Editor API Specification](docs/httpplugin/editor-api.md) for optional editor support)
- **Server**: [server](https://github.com/mankai-app/server) - a manga management and sync server implementing the API.

### Remote Image Processor

Remote image processors extend the ordered reader image pipeline with an HTTP service. The service supplies its own configuration schema and can optionally use the same JWT login and refresh flow as an HTTP plugin.

- **Specification**: [Remote Image Processor API](docs/imageprocessor/api.md)

## Remote Sources

Mankai supports remote sources for browsing and reading manga stored on remote services.

| Protocol     | Description                                                                                                                                        | Test Environment                                                                           |
| :----------- | :------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------- |
| **OPDS 1.2** | Browse OPDS 1.2 catalogs over HTTP or HTTPS with optional username and password authentication. Supports OPDS Page Streaming Extension (OPDS-PSE). | [Komga](https://github.com/gotson/komga), [calibre](https://github.com/kovidgoyal/calibre) |
| **SMB**      | Browse and read manga from an SMB share, with optional username and password authentication.                                                       | [crazy-max/docker-samba](https://github.com/crazy-max/docker-samba)                        |
| **SFTP**     | Browse, read, and import manga from an SFTP directory using username and password authentication.                                                  | openssh-server                                                                             |
| **NFS**      | Browse, read, and import manga from an exported NFS directory.                                                                                     | nfs-kernel-server                                                                          |
| **WebDAV**   | Browse and read manga from a WebDAV folder over HTTP or HTTPS, with optional username and password authentication.                                 | [hacdias/webdav](https://github.com/hacdias/webdav)                                        |

## Reader

Mankai provides two high-performance reading modes, both implemented in UIKit to ensure smooth scrolling and page transitions:

- **Continuous Reader**: A traditional webtoon-style vertical scrolling experience.
- **Paged Reader**: A paginated experience supporting vertical and horizontal navigation, with scroll and page-curl transition styles.

### Real-ESRGAN Upscaling

Mankai can optionally upscale low-resolution reader images to four times their original pixel dimensions with the `realesr-animevideov3` model.

- **Core ML Conversion**: [Real-ESRGAN-CoreML](https://github.com/mankai-app/Real-ESRGAN-CoreML)
- **Original Model**: [`realesr-animevideov3`](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/anime_video_model.md) from [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), licensed under the [BSD 3-Clause License](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE)

#### Performance

Core ML Performance Report medians on an **iPhone 15** running **iOS 26.6.1** for one 256 × 256 input tile (producing a 1024 × 1024 output tile):

| Compute Units                     | Prediction (Median) | Load (Median) | Compilation (Median) |
| :-------------------------------- | :------------------ | :------------ | :------------------- |
| **All (CPU, GPU, Neural Engine)** | 20.02 ms            | 17.71 ms      | 59.85 ms             |
| **CPU Only**                      | 102.59 ms           | 39.30 ms      | 122.43 ms            |
| **CPU + GPU**                     | 103.57 ms           | 11.57 ms      | 59.34 ms             |
| **CPU + Neural Engine**           | 20.34 ms            | 21.47 ms      | 60.64 ms             |

End-to-end page processing time varies with the source image dimensions because larger pages require more tiles.

### Smart Grouping

Mankai features an advanced **Smart Grouping** system that uses a deep learning model to detect and merge split-page spreads. By analyzing the visual adjacency of images, the app can automatically group two separate files into a single seamless spread, restoring the original artistic intent.

- **Model Repository**: [smart-grouping](https://github.com/mankai-app/smart-grouping)

#### Performance

| Metric            | Value                   |
| :---------------- | :---------------------- |
| **Base Model**    | `mobilenetv3_large_100` |
| **Test Accuracy** | 99.88%                  |
| **Precision**     | 99.90%                  |
| **Recall**        | 99.86%                  |
| **F1 Score**      | 99.88%                  |

#### Inference

Performance benchmarks on **iPhone 15**:

| Compute Units                     | Prediction (Median) | Load (Median) | Compilation (Median) |
| :-------------------------------- | :------------------ | :------------ | :------------------- |
| **All (CPU, GPU, Neural Engine)** | 0.94 ms             | 21.77 ms      | 65.11 ms             |
| **CPU Only**                      | 2.28 ms             | 17.94 ms      | 62.82 ms             |
| **CPU + GPU**                     | 8.15 ms             | 21.09 ms      | 81.25 ms             |
| **CPU + Neural Engine**           | 0.91 ms             | 45.80 ms      | 64.19 ms             |

## Syncing

Mankai supports syncing your library and reading history across devices using the following sync engines:

### HttpEngine

The **HttpEngine** requires a self-hosted server to function. You can use either of the following:

- **[server](https://github.com/mankai-app/server)** - A manga management and sync server, which can also serve as an [HttpPlugin](#http-plugin-httpplugin) source.
- **[sync](https://github.com/mankai-app/sync)** - A lightweight server dedicated solely to syncing.

Once hosted, you can configure the server URL in the app settings to enable syncing.

### SupabaseEngine

The **SupabaseEngine** allows you to sync using Supabase as the backend. You can set up your own Supabase project using the database schema provided in the [supabase](https://github.com/mankai-app/supabase) repository.

Once configured, you can enter your Supabase URL and Key in the app settings to enable syncing.

## Parsers

Mankai ships with built-in parsers that read local book files (e.g., CBZ, CBR, EPUB, and PDF) and extract their metadata and images. Each parser targets a specific file format.

| Parser         | Extensions | Description                                                                                           |
| :------------- | :--------- | :---------------------------------------------------------------------------------------------------- |
| **CbzParser**  | `.cbz`     | Parses Comic Book ZIP archives, extracting metadata from `ComicInfo.xml` and images from the archive. |
| **CbrParser**  | `.cbr`     | Parses Comic Book RAR archives, extracting metadata from `ComicInfo.xml` and images from the archive. |
| **EpubParser** | `.epub`    | Parses EPUB 2/3 publications, extracting package metadata and comic images in spine order.            |
| **PdfParser**  | `.pdf`     | Parses PDF documents and renders their pages as images.                                               |

## Development Notes

**Automatic Build Numbers**

The repository includes a pre-commit hook that formats all staged Swift files in parallel with `xcrun swift-format` and increments Xcode's `CURRENT_PROJECT_VERSION` for every target with `xcrun agvtool next-version -all`. The app and thumbnail extension build numbers stay synchronized.

Enable the version-controlled hooks once after cloning:

```sh
git config core.hooksPath .githooks
```

The hook stages formatter output and the updated Xcode project file automatically. If a staged Swift file or the project file has unstaged changes, the commit stops so unrelated edits are not staged silently, stage or stash those changes and retry the commit.

**Performance with Debugger Attached (e.g., from Xcode):**

- The startup time will be significantly slower than normal.
- The app may temporarily freeze on the first scroll in the reader screen.

These issues do not occur when running the app without a debugger attached.
