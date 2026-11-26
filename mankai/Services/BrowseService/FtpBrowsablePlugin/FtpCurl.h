//
//  FtpCurl.h
//  mankai
//
//  Created by Travis XU on 26/11/2026.
//

#ifndef MANKAI_FTP_CURL_H
#define MANKAI_FTP_CURL_H

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#include <curl/curl.h>
#pragma clang diagnostic pop

CURLcode MankaiFtpTransfer(CURL *handle, const char *url, const char *username,
                           const char *password, const char *caFile,
                           const char *listCommand, curl_off_t uploadSize,
                           long metadataOnly, void *context,
                           curl_write_callback writeCallback,
                           curl_read_callback readCallback,
                           curl_xferinfo_callback progressCallback,
                           char *errorBuffer, long *responseCode);

#endif
