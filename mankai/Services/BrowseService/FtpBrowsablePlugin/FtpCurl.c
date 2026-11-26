//
//  FtpCurl.c
//  mankai
//
//  Created by Travis XU on 26/11/2026.
//

#include "FtpCurl.h"

CURLcode MankaiFtpTransfer(CURL *handle, const char *url, const char *username,
                           const char *password, const char *caFile,
                           const char *listCommand, curl_off_t uploadSize,
                           long metadataOnly, void *context,
                           curl_write_callback writeCallback,
                           curl_read_callback readCallback,
                           curl_xferinfo_callback progressCallback,
                           char *errorBuffer, long *responseCode) {
  CURLcode result;
#define SET_OPTION(option, value)                                              \
  do {                                                                         \
    result = curl_easy_setopt(handle, option, value);                          \
    if (result != CURLE_OK)                                                    \
      goto done;                                                               \
  } while (0)

  SET_OPTION(CURLOPT_ERRORBUFFER, errorBuffer);
  SET_OPTION(CURLOPT_URL, url);
  SET_OPTION(CURLOPT_PROTOCOLS_STR, "ftp,sftp,ftps");
  SET_OPTION(CURLOPT_USERNAME, username);
  SET_OPTION(CURLOPT_PASSWORD, password);
  SET_OPTION(CURLOPT_NOSIGNAL, 1L);
  SET_OPTION(CURLOPT_CONNECTTIMEOUT, 15L);
  SET_OPTION(CURLOPT_LOW_SPEED_LIMIT, 1L);
  SET_OPTION(CURLOPT_LOW_SPEED_TIME, 30L);
  SET_OPTION(CURLOPT_FTP_RESPONSE_TIMEOUT, 30L);
  SET_OPTION(CURLOPT_SSH_AUTH_TYPES, (long)CURLSSH_AUTH_PASSWORD);
  SET_OPTION(CURLOPT_NOBODY, metadataOnly);
  SET_OPTION(CURLOPT_WRITEFUNCTION, writeCallback);
  SET_OPTION(CURLOPT_WRITEDATA, context);
  SET_OPTION(CURLOPT_NOPROGRESS, 0L);
  SET_OPTION(CURLOPT_XFERINFOFUNCTION, progressCallback);
  SET_OPTION(CURLOPT_XFERINFODATA, context);

  if (caFile) {
    SET_OPTION(CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    SET_OPTION(CURLOPT_CAINFO, caFile);
    SET_OPTION(CURLOPT_SSL_OPTIONS, CURLSSLOPT_NATIVE_CA);
  }
  if (listCommand) {
    SET_OPTION(CURLOPT_CUSTOMREQUEST, listCommand);
  }
  if (uploadSize >= 0) {
    SET_OPTION(CURLOPT_UPLOAD, 1L);
    SET_OPTION(CURLOPT_INFILESIZE_LARGE, uploadSize);
    SET_OPTION(CURLOPT_READFUNCTION, readCallback);
    SET_OPTION(CURLOPT_READDATA, context);
  }
  result = curl_easy_perform(handle);
  curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, responseCode);

done:
  // Release callback pointers and credentials per request, keeping the
  // connection cache.
  curl_easy_reset(handle);
  return result;
#undef SET_OPTION
}
