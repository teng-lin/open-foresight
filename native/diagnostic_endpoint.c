#include "diagnostic_endpoint.h"

#include <string.h>

static int broken(fs_diag_endpoint *endpoint) {
  if (endpoint != NULL) {
    endpoint->failed = 1;
    endpoint->send.failed = 1;
    endpoint->receive.failed = 1;
  }
  return FS_DIAG_CHANNEL_ERROR;
}

int fs_diag_endpoint_init(fs_diag_endpoint *endpoint, fs_diag_page *page,
                          int role) {
  if (endpoint == NULL)
    return FS_DIAG_CHANNEL_ERROR;
  memset(endpoint, 0, sizeof(*endpoint));
  endpoint->page = page;
  endpoint->role = role;
  endpoint->next_request_id = 1;
  if ((role != FS_DIAG_ENDPOINT_PARENT && role != FS_DIAG_ENDPOINT_CHILD) ||
      !fs_diag_page_supported(page))
    return broken(endpoint);
  return FS_DIAG_CHANNEL_COMPLETE;
}

static int valid_command(const fs_diag_endpoint *endpoint, uint8_t type,
                         uint64_t id) {
  if (endpoint->next_request_id == 1)
    return type == FS_DIAG_INIT && id == 1;
  if (type == FS_DIAG_INIT || id < 2)
    return 0;
  if (type == FS_DIAG_RETIRE && id == FS_DIAG_MAX_SEQUENCE)
    return 1;
  if (type != FS_DIAG_RETIRE && id >= FS_DIAG_MAX_SEQUENCE - 1)
    return 0;
  return id == endpoint->next_request_id &&
         (type == FS_DIAG_ADMIT || type == FS_DIAG_CLASSIFY ||
          type == FS_DIAG_APPEND || type == FS_DIAG_HEALTH ||
          type == FS_DIAG_RETIRE);
}

static int valid_reply(const fs_diag_endpoint *endpoint, uint8_t type,
                       uint64_t id) {
  if (!endpoint->hello)
    return type == FS_DIAG_HELLO && id == 0;
  return endpoint->pending_request_id != 0 &&
         id == endpoint->pending_request_id &&
         type == (endpoint->pending_type == FS_DIAG_RETIRE ? FS_DIAG_RETIRED
                                                           : FS_DIAG_RESULT);
}

int fs_diag_endpoint_send(fs_diag_endpoint *endpoint, uint8_t type,
                          uint64_t request_id, uint32_t total_length,
                          const uint8_t *chunk, uint32_t chunk_length) {
  if (endpoint == NULL || endpoint->failed || endpoint->retired)
    return broken(endpoint);
  int channel;
  if (endpoint->role == FS_DIAG_ENDPOINT_PARENT) {
    if (!endpoint->hello)
      return broken(endpoint);
    if (endpoint->pending_request_id != 0)
      return FS_DIAG_CHANNEL_EMPTY;
    if (endpoint->next_request_id >= FS_DIAG_MAX_SEQUENCE - 1 &&
        request_id == endpoint->next_request_id &&
        (type == FS_DIAG_ADMIT || type == FS_DIAG_CLASSIFY ||
         type == FS_DIAG_APPEND || type == FS_DIAG_HEALTH))
      return FS_DIAG_ENDPOINT_EXHAUSTED;
    if (!valid_command(endpoint, type, request_id))
      return broken(endpoint);
    channel = FS_DIAG_REQUEST_CHANNEL;
  } else {
    if (!valid_reply(endpoint, type, request_id))
      return broken(endpoint);
    channel = FS_DIAG_REPLY_CHANNEL;
  }
  int result = fs_diag_publish(endpoint->page, channel, &endpoint->send, type,
                               request_id, total_length, chunk, chunk_length);
  if (result == FS_DIAG_CHANNEL_ERROR)
    return broken(endpoint);
  if (result != FS_DIAG_CHANNEL_COMPLETE)
    return result;
  if (endpoint->role == FS_DIAG_ENDPOINT_PARENT) {
    endpoint->pending_request_id = request_id;
    endpoint->pending_type = type;
  } else if (!endpoint->hello) {
    endpoint->hello = 1;
  } else {
    endpoint->pending_request_id = 0;
    endpoint->retired = type == FS_DIAG_RETIRED;
  }
  return result;
}

int fs_diag_endpoint_receive(fs_diag_endpoint *endpoint, uint8_t *output,
                             uint32_t capacity, uint32_t *copied) {
  if (copied != NULL)
    *copied = 0;
  if (endpoint == NULL || endpoint->failed || endpoint->retired)
    return broken(endpoint);
  if (endpoint->role == FS_DIAG_ENDPOINT_CHILD &&
      endpoint->pending_request_id != 0)
    return FS_DIAG_CHANNEL_EMPTY;
  int channel = endpoint->role == FS_DIAG_ENDPOINT_PARENT
                    ? FS_DIAG_REPLY_CHANNEL
                    : FS_DIAG_REQUEST_CHANNEL;
  int result = fs_diag_receive(endpoint->page, channel, &endpoint->receive,
                               output, capacity, copied);
  if (result == FS_DIAG_CHANNEL_ERROR)
    return broken(endpoint);
  if (result != FS_DIAG_CHANNEL_COMPLETE)
    return result;
  uint8_t type = endpoint->receive.type;
  uint64_t id = endpoint->receive.request_id;
  if (endpoint->role == FS_DIAG_ENDPOINT_PARENT) {
    if (!valid_reply(endpoint, type, id)) {
      *copied = 0;
      return broken(endpoint);
    }
    if (!endpoint->hello) {
      endpoint->hello = 1;
    } else {
      endpoint->pending_request_id = 0;
      endpoint->retired = type == FS_DIAG_RETIRED;
      if (!endpoint->retired)
        ++endpoint->next_request_id;
    }
  } else {
    if (!endpoint->hello || !valid_command(endpoint, type, id)) {
      *copied = 0;
      return broken(endpoint);
    }
    endpoint->pending_request_id = id;
    endpoint->pending_type = type;
    if (id != FS_DIAG_MAX_SEQUENCE)
      endpoint->next_request_id = id + 1;
  }
  return result;
}
