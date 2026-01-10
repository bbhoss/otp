/*
 * Copyright Ericsson AB 2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * NIF interface for NVMe Key-Value operations via io_uring passthrough.
 *
 * This implementation uses the Linux io_uring command passthrough interface
 * to send NVMe KV commands directly to NVMe character devices (/dev/ngXnY).
 *
 * NVMe KV Command Set Opcodes (from NVMe KV Spec 1.1):
 * - Store:    0x01
 * - Retrieve: 0x02
 * - Delete:   0x10
 * - Exist:    0x14
 * - List:     0x06
 */

#include <erl_nif.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>

/* Check for io_uring support */
#ifdef __linux__
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 19, 0)
#define HAVE_IO_URING_CMD 1
#endif
#endif

#ifdef HAVE_IO_URING_CMD
#include <liburing.h>
#include <linux/nvme_ioctl.h>
#else
/* Fallback definitions for systems without io_uring_cmd */
#warning "io_uring command passthrough not available, using ioctl fallback"
#endif

/* NVMe KV Command Opcodes */
#define NVME_KV_CMD_STORE    0x01
#define NVME_KV_CMD_RETRIEVE 0x02
#define NVME_KV_CMD_DELETE   0x10
#define NVME_KV_CMD_EXIST    0x14
#define NVME_KV_CMD_LIST     0x06

/* NVMe KV specific CDW definitions */
/* CDW10: Key Size (bits 7:0) */
/* CDW11: Value Size (for Store/Retrieve) */

/* Maximum sizes */
#define MAX_KEY_SIZE    255
#define MAX_VALUE_SIZE  (2 * 1024 * 1024)  /* 2MB */
#define QUEUE_DEPTH     64
#define MAX_LIST_KEYS   1024

/* NVMe uring command structure (for kernels 5.19+) */
#ifndef NVME_URING_CMD_IO
#define NVME_URING_CMD_IO 0x00
#endif

/*
 * Use system definitions from linux/nvme_ioctl.h when available.
 * Only define our own structs when the system header doesn't provide them.
 */
#ifndef HAVE_IO_URING_CMD
/* Define structs only when not using io_uring (which includes nvme_ioctl.h) */
struct mnesia_nvme_uring_cmd {
    __u8  opcode;
    __u8  flags;
    __u16 rsvd1;
    __u32 nsid;
    __u32 cdw2;
    __u32 cdw3;
    __u64 metadata;
    __u64 addr;
    __u32 metadata_len;
    __u32 data_len;
    __u32 cdw10;
    __u32 cdw11;
    __u32 cdw12;
    __u32 cdw13;
    __u32 cdw14;
    __u32 cdw15;
    __u32 timeout_ms;
    __u32 rsvd2;
};

/* NVMe passthrough command for ioctl fallback */
struct mnesia_nvme_passthru_cmd {
    __u8  opcode;
    __u8  flags;
    __u16 rsvd1;
    __u32 nsid;
    __u32 cdw2;
    __u32 cdw3;
    __u64 metadata;
    __u64 addr;
    __u32 metadata_len;
    __u32 data_len;
    __u32 cdw10;
    __u32 cdw11;
    __u32 cdw12;
    __u32 cdw13;
    __u32 cdw14;
    __u32 cdw15;
    __u32 timeout_ms;
    __u32 result;
};
#endif /* !HAVE_IO_URING_CMD */

#ifndef NVME_IOCTL_IO_CMD
#define NVME_IOCTL_IO_CMD _IOWR('N', 0x43, struct nvme_passthru_cmd)
#endif

/* Device handle resource */
typedef struct {
    int fd;                        /* File descriptor for /dev/ngXnY */
    char device_path[256];
#ifdef HAVE_IO_URING_CMD
    struct io_uring ring;          /* io_uring instance */
    int ring_initialized;
#endif
} nvme_handle_t;

/* Resource type for device handles */
static ErlNifResourceType *nvme_handle_type = NULL;

/* Atoms */
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_not_found;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;
static ERL_NIF_TERM atom_enomem;
static ERL_NIF_TERM atom_enodev;
static ERL_NIF_TERM atom_eio;
static ERL_NIF_TERM atom_einval;

/*
 * Helper: Create error tuple
 */
static ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, atom_error, reason);
}

static ERL_NIF_TERM make_error_str(ErlNifEnv *env, const char *reason)
{
    return make_error(env, enif_make_atom(env, reason));
}

static ERL_NIF_TERM make_error_errno(ErlNifEnv *env, int err)
{
    switch (err) {
        case ENOMEM: return make_error(env, atom_enomem);
        case ENODEV:
        case ENOENT: return make_error(env, atom_enodev);
        case EIO:    return make_error(env, atom_eio);
        case EINVAL: return make_error(env, atom_einval);
        default:     return make_error_str(env, strerror(err));
    }
}

/*
 * Execute NVMe KV command via ioctl (fallback path)
 */
static int nvme_kv_ioctl(nvme_handle_t *handle, __u32 nsid, __u8 opcode,
                         const void *key, __u32 key_len,
                         void *data, __u32 data_len,
                         int is_write, __u32 *result)
{
    struct nvme_passthru_cmd cmd;
    int ret;

    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = opcode;
    cmd.nsid = nsid;
    cmd.addr = (__u64)(uintptr_t)data;
    cmd.data_len = data_len;

    /* CDW10: Key size in lower 8 bits */
    cmd.cdw10 = key_len & 0xFF;

    /* CDW11: Value/data length for store/retrieve */
    cmd.cdw11 = data_len;

    /* For commands that need key in metadata or cdw12-15 */
    /* The NVMe KV spec allows key to be inline in CDWs or via metadata pointer */
    /* For simplicity, use metadata pointer for key */
    cmd.metadata = (__u64)(uintptr_t)key;
    cmd.metadata_len = key_len;

    cmd.timeout_ms = 10000;  /* 10 second timeout */

    ret = ioctl(handle->fd, NVME_IOCTL_IO_CMD, &cmd);
    if (ret < 0) {
        return -errno;
    }

    if (result) {
        *result = cmd.result;
    }

    return 0;
}

#ifdef HAVE_IO_URING_CMD
/*
 * Execute NVMe KV command via io_uring passthrough
 */
static int nvme_kv_uring(nvme_handle_t *handle, __u32 nsid, __u8 opcode,
                         const void *key, __u32 key_len,
                         void *data, __u32 data_len,
                         int is_write, __u32 *result)
{
    struct io_uring_sqe *sqe;
    struct io_uring_cqe *cqe;
    struct nvme_uring_cmd *cmd;
    int ret;

    sqe = io_uring_get_sqe(&handle->ring);
    if (!sqe) {
        return -EAGAIN;
    }

    /* Setup uring command */
    io_uring_prep_rw(IORING_OP_URING_CMD, sqe, handle->fd, NULL, 0, 0);
    sqe->cmd_op = NVME_URING_CMD_IO;

    cmd = (struct nvme_uring_cmd *)sqe->cmd;
    memset(cmd, 0, sizeof(*cmd));
    cmd->opcode = opcode;
    cmd->nsid = nsid;
    cmd->addr = (__u64)(uintptr_t)data;
    cmd->data_len = data_len;
    cmd->cdw10 = key_len & 0xFF;
    cmd->cdw11 = data_len;
    cmd->metadata = (__u64)(uintptr_t)key;
    cmd->metadata_len = key_len;
    cmd->timeout_ms = 10000;

    ret = io_uring_submit(&handle->ring);
    if (ret < 0) {
        return ret;
    }

    ret = io_uring_wait_cqe(&handle->ring, &cqe);
    if (ret < 0) {
        return ret;
    }

    ret = cqe->res;
    io_uring_cqe_seen(&handle->ring, cqe);

    if (ret < 0) {
        return ret;
    }

    /* Result in big CQE if available */
    if (result) {
        *result = 0;  /* TODO: Extract from big CQE */
    }

    return 0;
}
#endif

/*
 * Execute NVMe KV command (dispatch to best available method)
 */
static int nvme_kv_cmd(nvme_handle_t *handle, __u32 nsid, __u8 opcode,
                       const void *key, __u32 key_len,
                       void *data, __u32 data_len,
                       int is_write, __u32 *result)
{
#ifdef HAVE_IO_URING_CMD
    if (handle->ring_initialized) {
        return nvme_kv_uring(handle, nsid, opcode, key, key_len,
                             data, data_len, is_write, result);
    }
#endif
    return nvme_kv_ioctl(handle, nsid, opcode, key, key_len,
                         data, data_len, is_write, result);
}

/*
 * Destructor for nvme_handle_t
 */
static void nvme_handle_dtor(ErlNifEnv *env, void *obj)
{
    nvme_handle_t *handle = (nvme_handle_t *)obj;
    (void)env;

#ifdef HAVE_IO_URING_CMD
    if (handle->ring_initialized) {
        io_uring_queue_exit(&handle->ring);
    }
#endif
    if (handle->fd >= 0) {
        close(handle->fd);
    }
}

/*
 * NIF: open(DevicePath) -> {ok, Handle} | {error, Reason}
 */
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char device_path[256];
    nvme_handle_t *handle;
    ERL_NIF_TERM handle_term;
    int fd;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (enif_get_string(env, argv[0], device_path, sizeof(device_path), ERL_NIF_LATIN1) <= 0) {
        return enif_make_badarg(env);
    }

    /* Open the NVMe character device */
    fd = open(device_path, O_RDWR);
    if (fd < 0) {
        return make_error_errno(env, errno);
    }

    /* Allocate handle resource */
    handle = enif_alloc_resource(nvme_handle_type, sizeof(nvme_handle_t));
    if (!handle) {
        close(fd);
        return make_error(env, atom_enomem);
    }

    memset(handle, 0, sizeof(*handle));
    handle->fd = fd;
    strncpy(handle->device_path, device_path, sizeof(handle->device_path) - 1);

#ifdef HAVE_IO_URING_CMD
    /* Try to initialize io_uring */
    if (io_uring_queue_init(QUEUE_DEPTH, &handle->ring, 0) == 0) {
        handle->ring_initialized = 1;
    }
#endif

    handle_term = enif_make_resource(env, handle);
    enif_release_resource(handle);

    return enif_make_tuple2(env, atom_ok, handle_term);
}

/*
 * NIF: close(Handle) -> ok | {error, Reason}
 */
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

#ifdef HAVE_IO_URING_CMD
    if (handle->ring_initialized) {
        io_uring_queue_exit(&handle->ring);
        handle->ring_initialized = 0;
    }
#endif

    if (handle->fd >= 0) {
        close(handle->fd);
        handle->fd = -1;
    }

    return atom_ok;
}

/*
 * NIF: store(Handle, Namespace, Key, Value) -> ok | {error, Reason}
 */
static ERL_NIF_TERM nif_store(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;
    unsigned int nsid;
    ErlNifBinary key, value;
    int ret;

    if (argc != 4) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_uint(env, argv[1], &nsid)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[2], &key)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[3], &value)) {
        return enif_make_badarg(env);
    }

    if (key.size > MAX_KEY_SIZE || value.size > MAX_VALUE_SIZE) {
        return make_error(env, atom_einval);
    }

    ret = nvme_kv_cmd(handle, nsid, NVME_KV_CMD_STORE,
                      key.data, key.size,
                      (void *)value.data, value.size,
                      1, NULL);

    if (ret < 0) {
        return make_error_errno(env, -ret);
    }

    return atom_ok;
}

/*
 * NIF: retrieve(Handle, Namespace, Key) -> {ok, Value} | {error, Reason}
 */
static ERL_NIF_TERM nif_retrieve(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;
    unsigned int nsid;
    ErlNifBinary key;
    unsigned char *value_buf;
    ERL_NIF_TERM value_term;
    __u32 actual_size;
    int ret;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_uint(env, argv[1], &nsid)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[2], &key)) {
        return enif_make_badarg(env);
    }

    if (key.size > MAX_KEY_SIZE) {
        return make_error(env, atom_einval);
    }

    /* Allocate buffer for value */
    value_buf = enif_alloc(MAX_VALUE_SIZE);
    if (!value_buf) {
        return make_error(env, atom_enomem);
    }

    ret = nvme_kv_cmd(handle, nsid, NVME_KV_CMD_RETRIEVE,
                      key.data, key.size,
                      value_buf, MAX_VALUE_SIZE,
                      0, &actual_size);

    if (ret < 0) {
        enif_free(value_buf);
        if (ret == -ENOENT || ret == -ENODATA) {
            return make_error(env, atom_not_found);
        }
        return make_error_errno(env, -ret);
    }

    /* Create binary for result */
    /* Note: actual_size should come from NVMe completion, but we may need to
     * handle this differently - for now assume full buffer or use a sentinel */
    unsigned char *result = enif_make_new_binary(env, actual_size > 0 ? actual_size : MAX_VALUE_SIZE, &value_term);
    memcpy(result, value_buf, actual_size > 0 ? actual_size : MAX_VALUE_SIZE);

    enif_free(value_buf);

    return enif_make_tuple2(env, atom_ok, value_term);
}

/*
 * NIF: delete(Handle, Namespace, Key) -> ok | {error, Reason}
 */
static ERL_NIF_TERM nif_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;
    unsigned int nsid;
    ErlNifBinary key;
    int ret;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_uint(env, argv[1], &nsid)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[2], &key)) {
        return enif_make_badarg(env);
    }

    ret = nvme_kv_cmd(handle, nsid, NVME_KV_CMD_DELETE,
                      key.data, key.size,
                      NULL, 0,
                      1, NULL);

    if (ret < 0 && ret != -ENOENT) {
        return make_error_errno(env, -ret);
    }

    return atom_ok;
}

/*
 * NIF: exists(Handle, Namespace, Key) -> boolean() | {error, Reason}
 */
static ERL_NIF_TERM nif_exists(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;
    unsigned int nsid;
    ErlNifBinary key;
    __u32 result;
    int ret;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_uint(env, argv[1], &nsid)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[2], &key)) {
        return enif_make_badarg(env);
    }

    ret = nvme_kv_cmd(handle, nsid, NVME_KV_CMD_EXIST,
                      key.data, key.size,
                      NULL, 0,
                      0, &result);

    if (ret < 0) {
        if (ret == -ENOENT || ret == -ENODATA) {
            return atom_false;
        }
        return make_error_errno(env, -ret);
    }

    /* Result indicates existence */
    return result ? atom_true : atom_false;
}

/*
 * NIF: list_keys(Handle, Namespace, Prefix) -> {ok, [Key]} | {error, Reason}
 */
static ERL_NIF_TERM nif_list_keys(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;
    unsigned int nsid;
    ErlNifBinary prefix;
    unsigned char *list_buf;
    ERL_NIF_TERM keys_list;
    int ret;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_uint(env, argv[1], &nsid)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[2], &prefix)) {
        return enif_make_badarg(env);
    }

    /* Allocate buffer for key list */
    list_buf = enif_alloc(MAX_LIST_KEYS * MAX_KEY_SIZE);
    if (!list_buf) {
        return make_error(env, atom_enomem);
    }

    ret = nvme_kv_cmd(handle, nsid, NVME_KV_CMD_LIST,
                      prefix.data, prefix.size,
                      list_buf, MAX_LIST_KEYS * MAX_KEY_SIZE,
                      0, NULL);

    if (ret < 0) {
        enif_free(list_buf);
        if (ret == -ENOENT) {
            return enif_make_tuple2(env, atom_ok, enif_make_list(env, 0));
        }
        return make_error_errno(env, -ret);
    }

    /* Parse the key list from buffer.
     * NVMe KV List command returns keys in a specific format.
     * Format: Each key is prefixed with its length (1 byte for keys <= 255 bytes).
     * We need to parse and filter by prefix.
     */
    keys_list = enif_make_list(env, 0);

    /* TODO: Parse actual NVMe KV list response format */
    /* For now, return empty list - actual parsing depends on device */

    enif_free(list_buf);

    return enif_make_tuple2(env, atom_ok, keys_list);
}

/*
 * NIF: info(Handle) -> {ok, Map} | {error, Reason}
 */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    nvme_handle_t *handle;
    ERL_NIF_TERM map;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], nvme_handle_type, (void **)&handle)) {
        return enif_make_badarg(env);
    }

    map = enif_make_new_map(env);

    enif_make_map_put(env, map,
                      enif_make_atom(env, "device_path"),
                      enif_make_string(env, handle->device_path, ERL_NIF_LATIN1),
                      &map);

    enif_make_map_put(env, map,
                      enif_make_atom(env, "fd"),
                      enif_make_int(env, handle->fd),
                      &map);

#ifdef HAVE_IO_URING_CMD
    enif_make_map_put(env, map,
                      enif_make_atom(env, "io_uring"),
                      handle->ring_initialized ? atom_true : atom_false,
                      &map);
#else
    enif_make_map_put(env, map,
                      enif_make_atom(env, "io_uring"),
                      atom_false,
                      &map);
#endif

    enif_make_map_put(env, map,
                      enif_make_atom(env, "max_key_size"),
                      enif_make_int(env, MAX_KEY_SIZE),
                      &map);

    enif_make_map_put(env, map,
                      enif_make_atom(env, "max_value_size"),
                      enif_make_int(env, MAX_VALUE_SIZE),
                      &map);

    return enif_make_tuple2(env, atom_ok, map);
}

/*
 * NIF initialization
 */
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    /* Create resource type for device handles */
    nvme_handle_type = enif_open_resource_type(
        env,
        NULL,
        "nvme_handle",
        nvme_handle_dtor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL
    );

    if (!nvme_handle_type) {
        return -1;
    }

    /* Initialize atoms */
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_not_found = enif_make_atom(env, "not_found");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    atom_enomem = enif_make_atom(env, "enomem");
    atom_enodev = enif_make_atom(env, "enodev");
    atom_eio = enif_make_atom(env, "eio");
    atom_einval = enif_make_atom(env, "einval");

    return 0;
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info)
{
    (void)old_priv_data;
    return load(env, priv_data, load_info);
}

static ErlNifFunc nif_funcs[] = {
    {"open",      1, nif_open,      0},
    {"close",     1, nif_close,     0},
    {"store",     4, nif_store,     0},
    {"retrieve",  3, nif_retrieve,  0},
    {"delete",    3, nif_delete,    0},
    {"exists",    3, nif_exists,    0},
    {"list_keys", 3, nif_list_keys, 0},
    {"info",      1, nif_info,      0}
};

ERL_NIF_INIT(mnesia_nvme_nif, nif_funcs, load, NULL, upgrade, NULL)
