#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <mach-o/dyld.h>

extern char **environ;

static void die_usage(const char *msg) {
  if (msg && msg[0] != '\0') {
    fprintf(stderr, "error: %s\n", msg);
  }
  fprintf(stderr, "usage: turbodraft-open --path <file> [--line N] [--column N] [--wait] [--timeout-ms N] [--socket-path <path>]\n");
  exit(2);
}

static int64_t now_mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static char *dup_str(const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s);
  char *out = (char *)malloc(n + 1);
  if (!out) return NULL;
  memcpy(out, s, n);
  out[n] = '\0';
  return out;
}

static char *join2(const char *a, const char *b) {
  if (!a || !b) return NULL;
  size_t na = strlen(a);
  size_t nb = strlen(b);
  char *out = (char *)malloc(na + nb + 1);
  if (!out) return NULL;
  memcpy(out, a, na);
  memcpy(out + na, b, nb);
  out[na + nb] = '\0';
  return out;
}

static char *default_support_dir(void) {
  const char *home = getenv("HOME");
  if (!home || home[0] == '\0') {
    return dup_str("/tmp");
  }
  // ~/Library/Application Support/TurboDraft
  char buf[4096];
  snprintf(buf, sizeof(buf), "%s/Library/Application Support/TurboDraft", home);
  return dup_str(buf);
}

static char *default_socket_path(void) {
  char *dir = default_support_dir();
  if (!dir) return NULL;
  char *out = join2(dir, "/turbodraft.sock");
  free(dir);
  return out;
}

static char *default_config_path(void) {
  char *dir = default_support_dir();
  if (!dir) return NULL;
  char *out = join2(dir, "/config.json");
  free(dir);
  return out;
}

static bool read_file(const char *path, char **out_buf, size_t *out_len) {
  *out_buf = NULL;
  *out_len = 0;
  struct stat st;
  if (stat(path, &st) != 0) {
    return false;
  }
  if (st.st_size <= 0 || st.st_size > (1024 * 1024)) {
    return false;
  }
  FILE *f = fopen(path, "rb");
  if (!f) return false;
  size_t n = (size_t)st.st_size;
  char *buf = (char *)malloc(n + 1);
  if (!buf) {
    fclose(f);
    return false;
  }
  size_t r = fread(buf, 1, n, f);
  fclose(f);
  if (r != n) {
    free(buf);
    return false;
  }
  buf[n] = '\0';
  *out_buf = buf;
  *out_len = n;
  return true;
}

static int hex_digit_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
  if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
  return -1;
}

static bool append_utf8_codepoint(char *out, size_t cap, size_t *len, unsigned cp) {
  if (cp <= 0x7F) {
    if (*len + 1 >= cap) return false;
    out[(*len)++] = (char)cp;
    return true;
  }
  if (cp <= 0x7FF) {
    if (*len + 2 >= cap) return false;
    out[(*len)++] = (char)(0xC0 | (cp >> 6));
    out[(*len)++] = (char)(0x80 | (cp & 0x3F));
    return true;
  }
  if (cp <= 0xFFFF) {
    if (*len + 3 >= cap) return false;
    out[(*len)++] = (char)(0xE0 | (cp >> 12));
    out[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[(*len)++] = (char)(0x80 | (cp & 0x3F));
    return true;
  }
  if (cp <= 0x10FFFF) {
    if (*len + 4 >= cap) return false;
    out[(*len)++] = (char)(0xF0 | (cp >> 18));
    out[(*len)++] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[(*len)++] = (char)(0x80 | (cp & 0x3F));
    return true;
  }
  return false;
}

static bool json_extract_string_value(const char *json, const char *key, char **out_value) {
  *out_value = NULL;
  const char *p = strstr(json, key);
  if (!p) return false;
  p += strlen(key);
  p = strchr(p, ':');
  if (!p) return false;
  p++;
  while (*p && isspace((unsigned char)*p)) p++;
  if (*p != '\"') return false;
  p++;

  size_t cap = strlen(p) + 1;
  char *out = (char *)malloc(cap);
  if (!out) return false;
  size_t len = 0;

  while (*p) {
    unsigned char c = (unsigned char)*p++;
    if (c == '\"') {
      out[len] = '\0';
      *out_value = out;
      return true;
    }

    if (c != '\\') {
      if (len + 1 >= cap) { free(out); return false; }
      out[len++] = (char)c;
      continue;
    }

    unsigned char esc = (unsigned char)*p++;
    if (esc == '\0') break;
    switch (esc) {
      case '\"':
      case '\\':
      case '/':
        if (len + 1 >= cap) { free(out); return false; }
        out[len++] = (char)esc;
        break;
      case 'b':
        if (len + 1 >= cap) { free(out); return false; }
        out[len++] = '\b';
        break;
      case 'f':
        if (len + 1 >= cap) { free(out); return false; }
        out[len++] = '\f';
        break;
      case 'n':
        if (len + 1 >= cap) { free(out); return false; }
        out[len++] = '\n';
        break;
      case 'r':
        if (len + 1 >= cap) { free(out); return false; }
        out[len++] = '\r';
        break;
      case 't':
        if (len + 1 >= cap) { free(out); return false; }
        out[len++] = '\t';
        break;
      case 'u': {
        int h1 = hex_digit_value(*p++);
        int h2 = hex_digit_value(*p++);
        int h3 = hex_digit_value(*p++);
        int h4 = hex_digit_value(*p++);
        if (h1 < 0 || h2 < 0 || h3 < 0 || h4 < 0) { free(out); return false; }
        unsigned cp = (unsigned)((h1 << 12) | (h2 << 8) | (h3 << 4) | h4);
        if (!append_utf8_codepoint(out, cap, &len, cp)) { free(out); return false; }
        break;
      }
      default:
        free(out);
        return false;
    }
  }

  free(out);
  return false;
}

static char *resolve_socket_path(void) {
  const char *explicitSock = getenv("TURBODRAFT_SOCKET");
  if (explicitSock && explicitSock[0] != '\0') {
    return dup_str(explicitSock);
  }

  const char *cfgPathEnv = getenv("TURBODRAFT_CONFIG");
  char *cfgPath = cfgPathEnv && cfgPathEnv[0] != '\0' ? dup_str(cfgPathEnv) : default_config_path();
  if (cfgPath) {
    char *buf = NULL;
    size_t len = 0;
    if (read_file(cfgPath, &buf, &len)) {
      char *sock = NULL;
      if (json_extract_string_value(buf, "\"socketPath\"", &sock)) {
        free(buf);
        free(cfgPath);
        return sock;
      }
      free(buf);
    }
    free(cfgPath);
  }

  return default_socket_path();
}

static char *dirname_dup(const char *path) {
  if (!path) return NULL;
  const char *slash = strrchr(path, '/');
  if (!slash) return NULL;
  size_t n = (size_t)(slash - path);
  if (n == 0) n = 1; // root
  char *out = (char *)malloc(n + 1);
  if (!out) return NULL;
  memcpy(out, path, n);
  out[n] = '\0';
  return out;
}

static char *current_executable_realpath(void) {
  uint32_t size = 0;
  _NSGetExecutablePath(NULL, &size);
  if (size == 0) return NULL;
  char *buf = (char *)malloc((size_t)size + 1);
  if (!buf) return NULL;
  if (_NSGetExecutablePath(buf, &size) != 0) {
    free(buf);
    return NULL;
  }
  buf[size] = '\0';

  char *resolved = realpath(buf, NULL);
  free(buf);
  if (resolved) return resolved;
  return NULL;
}

static bool try_spawn_path(const char *exe_path) {
  if (!exe_path || exe_path[0] == '\0') return false;
  if (access(exe_path, X_OK) != 0) return false;
  pid_t pid = 0;
  char *argv[] = { (char *)exe_path, "--start-hidden", NULL };
  return posix_spawn(&pid, exe_path, NULL, NULL, argv, environ) == 0;
}

static void launch_app_best_effort(void) {
  char *self_path = current_executable_realpath();
  if (self_path) {
    char *dir = dirname_dup(self_path);
    if (dir) {
      char *candidate = join2(dir, "/turbodraft-app");
      if (candidate) {
        if (try_spawn_path(candidate)) {
          free(candidate);
          free(dir);
          free(self_path);
          return;
        }
        free(candidate);
      }
      free(dir);
    }
    free(self_path);
  }

  // Fallback to PATH.
  pid_t pid = 0;
  char *argv[] = { "turbodraft-app", "--start-hidden", NULL };
  (void)posix_spawnp(&pid, "turbodraft-app", NULL, NULL, argv, environ);
}

static int connect_or_launch(const char *sock_path, int timeout_ms) {
  int64_t deadline = now_mono_ms() + (timeout_ms < 0 ? 0 : timeout_ms);
  bool did_launch = false;
  int sleep_us = 5 * 1000;

  while (now_mono_ms() < deadline) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t maxLen = sizeof(addr.sun_path);
    if (strlen(sock_path) >= maxLen) {
      close(fd);
      errno = ENAMETOOLONG;
      return -1;
    }
    strncpy(addr.sun_path, sock_path, maxLen - 1);

    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr)) == 0) {
      return fd;
    }
    close(fd);

    if (!did_launch) {
      did_launch = true;
      launch_app_best_effort();
    }
    usleep((useconds_t)sleep_us);
    if (sleep_us < 25 * 1000) {
      sleep_us += 3 * 1000;
    }
  }
  errno = ETIMEDOUT;
  return -1;
}

static int write_all(int fd, const uint8_t *buf, size_t len) {
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, buf + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) {
      errno = EPIPE;
      return -1;
    }
    off += (size_t)n;
  }
  return 0;
}

struct framer {
  uint8_t *buf;
  size_t len;
  size_t cap;
};

static void framer_init(struct framer *f) {
  f->buf = NULL;
  f->len = 0;
  f->cap = 0;
}

static void framer_free(struct framer *f) {
  free(f->buf);
  f->buf = NULL;
  f->len = 0;
  f->cap = 0;
}

static int framer_append(struct framer *f, const uint8_t *data, size_t n) {
  if (n == 0) return 0;
  if (f->len + n > f->cap) {
    size_t newCap = f->cap == 0 ? 8192 : f->cap;
    while (newCap < f->len + n) newCap *= 2;
    uint8_t *nb = (uint8_t *)realloc(f->buf, newCap);
    if (!nb) return -1;
    f->buf = nb;
    f->cap = newCap;
  }
  memcpy(f->buf + f->len, data, n);
  f->len += n;
  return 0;
}

static int parse_content_length(const char *headers, size_t headers_len, int *out_len) {
  *out_len = -1;
  const char *p = headers;
  const char *end = headers + headers_len;
  while (p < end) {
    const char *line_end = strstr(p, "\r\n");
    if (!line_end || line_end > end) break;
    const char *colon = memchr(p, ':', (size_t)(line_end - p));
    if (colon) {
      size_t key_len = (size_t)(colon - p);
      if (key_len == strlen("Content-Length") && strncasecmp(p, "Content-Length", key_len) == 0) {
        const char *v = colon + 1;
        while (v < line_end && isspace((unsigned char)*v)) v++;
        char tmp[64];
        size_t vn = (size_t)(line_end - v);
        if (vn >= sizeof(tmp)) return -1;
        memcpy(tmp, v, vn);
        tmp[vn] = '\0';
        int n = atoi(tmp);
        if (n < 0) return -1;
        *out_len = n;
        return 0;
      }
    }
    p = line_end + 2;
  }
  return -1;
}

static int framer_read_frame(int fd, struct framer *f, int timeout_ms, uint8_t **out_body, size_t *out_body_len) {
  *out_body = NULL;
  *out_body_len = 0;
  int64_t deadline = now_mono_ms() + (timeout_ms < 0 ? 0 : timeout_ms);

  while (true) {
    // Try to parse a frame from current buffer.
    for (size_t i = 3; i < f->len; i++) {
      if (f->buf[i - 3] == '\r' && f->buf[i - 2] == '\n' && f->buf[i - 1] == '\r' && f->buf[i] == '\n') {
        size_t headers_len = i - 3;
        const char *headers = (const char *)f->buf;
        int body_len = -1;
        if (parse_content_length(headers, headers_len, &body_len) != 0 || body_len < 0) {
          errno = EPROTO;
          return -1;
        }
        size_t body_start = i + 1;
        size_t body_end = body_start + (size_t)body_len;
        if (f->len < body_end) {
          break; // need more data
        }
        uint8_t *body = (uint8_t *)malloc((size_t)body_len + 1);
        if (!body) return -1;
        memcpy(body, f->buf + body_start, (size_t)body_len);
        body[body_len] = 0;

        // Remove this frame from buffer.
        size_t remaining = f->len - body_end;
        if (remaining > 0) {
          memmove(f->buf, f->buf + body_end, remaining);
        }
        f->len = remaining;

        *out_body = body;
        *out_body_len = (size_t)body_len;
        return 0;
      }
    }

    int64_t now = now_mono_ms();
    int remain = (int)(deadline - now);
    if (remain <= 0) {
      errno = ETIMEDOUT;
      return -1;
    }

    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    int pr = poll(&pfd, 1, remain);
    if (pr < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (pr == 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    if (pfd.revents & POLLIN) {
      uint8_t tmp[8192];
      ssize_t n = read(fd, tmp, sizeof(tmp));
      if (n < 0) {
        if (errno == EINTR) continue;
        return -1;
      }
      if (n == 0) {
        errno = EPIPE;
        return -1;
      }
      if (framer_append(f, tmp, (size_t)n) != 0) {
        errno = ENOMEM;
        return -1;
      }
      continue;
    }
  }
}

static char *json_escape(const char *s) {
  if (!s) return dup_str("");
  size_t in_len = strlen(s);
  size_t cap = in_len * 2 + 32;
  char *out = (char *)malloc(cap);
  if (!out) return NULL;
  size_t o = 0;

  for (size_t i = 0; i < in_len; i++) {
    unsigned char c = (unsigned char)s[i];
    const char *rep = NULL;
    char tmp[7];
    if (c == '\"') rep = "\\\"";
    else if (c == '\\') rep = "\\\\";
    else if (c == '\n') rep = "\\n";
    else if (c == '\r') rep = "\\r";
    else if (c == '\t') rep = "\\t";
    else if (c < 0x20) {
      snprintf(tmp, sizeof(tmp), "\\u%04x", (unsigned)c);
      rep = tmp;
    }

    if (rep) {
      size_t rn = strlen(rep);
      if (o + rn + 1 >= cap) {
        cap *= 2;
        char *nb = (char *)realloc(out, cap);
        if (!nb) { free(out); return NULL; }
        out = nb;
      }
      memcpy(out + o, rep, rn);
      o += rn;
    } else {
      if (o + 2 >= cap) {
        cap *= 2;
        char *nb = (char *)realloc(out, cap);
        if (!nb) { free(out); return NULL; }
        out = nb;
      }
      out[o++] = (char)c;
    }
  }
  out[o] = '\0';
  return out;
}

static int send_jsonrpc(int fd, const char *json) {
  char header[128];
  int json_len = (int)strlen(json);
  int hn = snprintf(header, sizeof(header), "Content-Length: %d\r\n\r\n", json_len);
  if (hn <= 0 || hn >= (int)sizeof(header)) {
    errno = EOVERFLOW;
    return -1;
  }
  if (write_all(fd, (const uint8_t *)header, (size_t)hn) != 0) return -1;
  if (write_all(fd, (const uint8_t *)json, (size_t)json_len) != 0) return -1;
  return 0;
}

static bool response_has_error(const char *body) {
  return body && strstr(body, "\"error\"") != NULL && strstr(body, "\"error\":null") == NULL;
}

static bool extract_session_id(const char *body, char **out_session_id) {
  *out_session_id = NULL;
  if (!body) return false;
  return json_extract_string_value(body, "\"sessionId\"", out_session_id);
}

static char *format_open_request_json(const char *path_escaped, int line, int column) {
  const char *fmt = NULL;
  if (line > 0 && column > 0) {
    fmt = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"turbodraft.session.open\",\"params\":{\"path\":\"%s\",\"line\":%d,\"column\":%d}}";
  } else if (line > 0) {
    fmt = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"turbodraft.session.open\",\"params\":{\"path\":\"%s\",\"line\":%d}}";
  } else {
    fmt = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"turbodraft.session.open\",\"params\":{\"path\":\"%s\"}}";
  }

  int n = (line > 0 && column > 0)
    ? snprintf(NULL, 0, fmt, path_escaped, line, column)
    : (line > 0 ? snprintf(NULL, 0, fmt, path_escaped, line) : snprintf(NULL, 0, fmt, path_escaped));
  if (n < 0) return NULL;

  char *out = (char *)malloc((size_t)n + 1);
  if (!out) return NULL;
  if (line > 0 && column > 0) {
    snprintf(out, (size_t)n + 1, fmt, path_escaped, line, column);
  } else if (line > 0) {
    snprintf(out, (size_t)n + 1, fmt, path_escaped, line);
  } else {
    snprintf(out, (size_t)n + 1, fmt, path_escaped);
  }
  return out;
}

static char *format_wait_request_json(const char *session_id, int timeout_ms) {
  const char *fmt = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"turbodraft.session.wait\",\"params\":{\"sessionId\":\"%s\",\"timeoutMs\":%d}}";
  int n = snprintf(NULL, 0, fmt, session_id, timeout_ms);
  if (n < 0) return NULL;
  char *out = (char *)malloc((size_t)n + 1);
  if (!out) return NULL;
  snprintf(out, (size_t)n + 1, fmt, session_id, timeout_ms);
  return out;
}

int main(int argc, char **argv) {
  const char *path = NULL;
  int line = -1;
  int column = -1;
  bool wait = false;
  int timeout_ms = 600000;
  char *socket_path_override = NULL;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--path") == 0) {
      if (i + 1 >= argc) die_usage("missing value for --path");
      path = argv[++i];
    } else if (strcmp(a, "--line") == 0) {
      if (i + 1 >= argc) die_usage("missing value for --line");
      line = atoi(argv[++i]);
    } else if (strcmp(a, "--column") == 0) {
      if (i + 1 >= argc) die_usage("missing value for --column");
      column = atoi(argv[++i]);
    } else if (strcmp(a, "--timeout-ms") == 0) {
      if (i + 1 >= argc) die_usage("missing value for --timeout-ms");
      timeout_ms = atoi(argv[++i]);
    } else if (strcmp(a, "--wait") == 0) {
      wait = true;
    } else if (strcmp(a, "--socket-path") == 0) {
      if (i + 1 >= argc) die_usage("missing value for --socket-path");
      socket_path_override = dup_str(argv[++i]);
    } else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
      die_usage(NULL);
    } else {
      die_usage("unknown argument");
    }
  }

  if (!path || path[0] == '\0') die_usage("missing --path");

  char *socket_path = socket_path_override ? socket_path_override : resolve_socket_path();
  if (!socket_path) {
    fprintf(stderr, "error: failed to resolve socket path\n");
    return 1;
  }

  int fd = connect_or_launch(socket_path, timeout_ms);
  if (fd < 0) {
    fprintf(stderr, "error: connect failed: %s\n", strerror(errno));
    free(socket_path);
    return 1;
  }

  char *path_escaped = json_escape(path);
  if (!path_escaped) {
    fprintf(stderr, "error: OOM\n");
    close(fd);
    free(socket_path);
    return 1;
  }

  char *open_json = format_open_request_json(path_escaped, line, column);
  free(path_escaped);
  if (!open_json) {
    fprintf(stderr, "error: failed to format open request\n");
    close(fd);
    free(socket_path);
    return 1;
  }

  if (send_jsonrpc(fd, open_json) != 0) {
    fprintf(stderr, "error: write failed: %s\n", strerror(errno));
    free(open_json);
    close(fd);
    free(socket_path);
    return 1;
  }
  free(open_json);

  struct framer fr;
  framer_init(&fr);
  uint8_t *body = NULL;
  size_t body_len = 0;
  if (framer_read_frame(fd, &fr, timeout_ms, &body, &body_len) != 0) {
    fprintf(stderr, "error: read response failed: %s\n", strerror(errno));
    framer_free(&fr);
    close(fd);
    free(socket_path);
    return 1;
  }
  const char *resp = (const char *)body;
  if (response_has_error(resp)) {
    fprintf(stderr, "error: server returned error: %s\n", resp);
    free(body);
    framer_free(&fr);
    close(fd);
    free(socket_path);
    return 1;
  }

  char *session_id = NULL;
  if (!extract_session_id(resp, &session_id) || !session_id) {
    fprintf(stderr, "error: failed to parse sessionId\n");
    free(body);
    framer_free(&fr);
    close(fd);
    free(socket_path);
    return 1;
  }
  free(body);

  if (wait) {
    char *wait_json = format_wait_request_json(session_id, timeout_ms);
    if (!wait_json) {
      fprintf(stderr, "error: failed to format wait request\n");
      free(session_id);
      framer_free(&fr);
      close(fd);
      free(socket_path);
      return 1;
    }

    if (send_jsonrpc(fd, wait_json) != 0) {
      fprintf(stderr, "error: wait write failed: %s\n", strerror(errno));
      free(wait_json);
      free(session_id);
      framer_free(&fr);
      close(fd);
      free(socket_path);
      return 1;
    }
    free(wait_json);

    uint8_t *wait_body = NULL;
    size_t wait_len = 0;
    if (framer_read_frame(fd, &fr, timeout_ms, &wait_body, &wait_len) != 0) {
      fprintf(stderr, "error: wait read failed: %s\n", strerror(errno));
      free(session_id);
      framer_free(&fr);
      close(fd);
      free(socket_path);
      return 1;
    }
    free(wait_body);
  }

  free(session_id);
  framer_free(&fr);
  close(fd);
  free(socket_path);
  return 0;
}
