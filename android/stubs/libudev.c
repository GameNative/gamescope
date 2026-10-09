/*
 * libudev stub implementation — Android/bionic has no udev. All discovery
 * returns "empty", monitors never fire. Objects are refcounted dummies so
 * ref/unref semantics stay valid for callers that pass them around.
 */
#include "libudev.h"

#include <stdlib.h>
#include <string.h>

struct stub_obj {
    unsigned long refcount;
};

static void *stub_alloc(void)
{
    struct stub_obj *o = calloc(1, sizeof(*o));
    if (o)
        o->refcount = 1;
    return o;
}

static void *stub_ref(void *p)
{
    if (p)
        ((struct stub_obj *)p)->refcount++;
    return p;
}

static void *stub_unref(void *p)
{
    if (p && --((struct stub_obj *)p)->refcount == 0)
        free(p);
    return NULL;
}

/* ---- udev ---- */
struct udev *udev_new(void) { return stub_alloc(); }
struct udev *udev_ref(struct udev *udev) { return stub_ref(udev); }
struct udev *udev_unref(struct udev *udev) { return stub_unref(udev); }
int udev_get_log_priority(struct udev *udev) { (void)udev; return 0; }
void udev_set_log_priority(struct udev *udev, int priority) { (void)udev; (void)priority; }
void *udev_get_userdata(struct udev *udev) { (void)udev; return NULL; }
void udev_set_userdata(struct udev *udev, void *userdata) { (void)udev; (void)userdata; }

/* ---- list entries (always empty) ---- */
struct udev_list_entry *udev_list_entry_get_next(struct udev_list_entry *e) { (void)e; return NULL; }
struct udev_list_entry *udev_list_entry_get_by_name(struct udev_list_entry *e, const char *name) { (void)e; (void)name; return NULL; }
const char *udev_list_entry_get_name(struct udev_list_entry *e) { (void)e; return NULL; }
const char *udev_list_entry_get_value(struct udev_list_entry *e) { (void)e; return NULL; }

/* ---- devices ----
 * new_from_* return NULL: there is no device database, so lookups fail —
 * callers treat this exactly like "no such device" on a real system. */
struct udev_device *udev_device_ref(struct udev_device *d) { return stub_ref(d); }
struct udev_device *udev_device_unref(struct udev_device *d) { return stub_unref(d); }
struct udev *udev_device_get_udev(struct udev_device *d) { (void)d; return NULL; }
struct udev_device *udev_device_new_from_syspath(struct udev *u, const char *syspath) { (void)u; (void)syspath; return NULL; }
struct udev_device *udev_device_new_from_devnum(struct udev *u, char type, dev_t devnum) { (void)u; (void)type; (void)devnum; return NULL; }
struct udev_device *udev_device_new_from_subsystem_sysname(struct udev *u, const char *s, const char *n) { (void)u; (void)s; (void)n; return NULL; }
struct udev_device *udev_device_new_from_device_id(struct udev *u, const char *id) { (void)u; (void)id; return NULL; }
struct udev_device *udev_device_new_from_environment(struct udev *u) { (void)u; return NULL; }
struct udev_device *udev_device_get_parent(struct udev_device *d) { (void)d; return NULL; }
struct udev_device *udev_device_get_parent_with_subsystem_devtype(struct udev_device *d, const char *s, const char *t) { (void)d; (void)s; (void)t; return NULL; }
const char *udev_device_get_devpath(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_syspath(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_sysname(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_sysnum(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_devnode(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_devtype(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_subsystem(struct udev_device *d) { (void)d; return NULL; }
const char *udev_device_get_driver(struct udev_device *d) { (void)d; return NULL; }
dev_t udev_device_get_devnum(struct udev_device *d) { (void)d; return makedev(0, 0); }
const char *udev_device_get_action(struct udev_device *d) { (void)d; return NULL; }
unsigned long long int udev_device_get_seqnum(struct udev_device *d) { (void)d; return 0; }
unsigned long long int udev_device_get_usec_since_initialized(struct udev_device *d) { (void)d; return 0; }
const char *udev_device_get_sysattr_value(struct udev_device *d, const char *sysattr) { (void)d; (void)sysattr; return NULL; }
int udev_device_set_sysattr_value(struct udev_device *d, const char *sysattr, const char *value) { (void)d; (void)sysattr; (void)value; return -1; }
const char *udev_device_get_property_value(struct udev_device *d, const char *key) { (void)d; (void)key; return NULL; }
int udev_device_has_tag(struct udev_device *d, const char *tag) { (void)d; (void)tag; return 0; }
int udev_device_get_is_initialized(struct udev_device *d) { (void)d; return 0; }
struct udev_list_entry *udev_device_get_devlinks_list_entry(struct udev_device *d) { (void)d; return NULL; }
struct udev_list_entry *udev_device_get_properties_list_entry(struct udev_device *d) { (void)d; return NULL; }
struct udev_list_entry *udev_device_get_tags_list_entry(struct udev_device *d) { (void)d; return NULL; }
struct udev_list_entry *udev_device_get_sysattr_list_entry(struct udev_device *d) { (void)d; return NULL; }

/* ---- enumerate (zero devices) ---- */
struct udev_enumerate *udev_enumerate_new(struct udev *u) { (void)u; return stub_alloc(); }
struct udev_enumerate *udev_enumerate_ref(struct udev_enumerate *e) { return stub_ref(e); }
struct udev_enumerate *udev_enumerate_unref(struct udev_enumerate *e) { return stub_unref(e); }
struct udev *udev_enumerate_get_udev(struct udev_enumerate *e) { (void)e; return NULL; }
int udev_enumerate_add_match_subsystem(struct udev_enumerate *e, const char *s) { (void)e; (void)s; return 0; }
int udev_enumerate_add_nomatch_subsystem(struct udev_enumerate *e, const char *s) { (void)e; (void)s; return 0; }
int udev_enumerate_add_match_sysattr(struct udev_enumerate *e, const char *a, const char *v) { (void)e; (void)a; (void)v; return 0; }
int udev_enumerate_add_nomatch_sysattr(struct udev_enumerate *e, const char *a, const char *v) { (void)e; (void)a; (void)v; return 0; }
int udev_enumerate_add_match_property(struct udev_enumerate *e, const char *p, const char *v) { (void)e; (void)p; (void)v; return 0; }
int udev_enumerate_add_match_sysname(struct udev_enumerate *e, const char *n) { (void)e; (void)n; return 0; }
int udev_enumerate_add_match_tag(struct udev_enumerate *e, const char *t) { (void)e; (void)t; return 0; }
int udev_enumerate_add_match_parent(struct udev_enumerate *e, struct udev_device *p) { (void)e; (void)p; return 0; }
int udev_enumerate_add_match_is_initialized(struct udev_enumerate *e) { (void)e; return 0; }
int udev_enumerate_add_syspath(struct udev_enumerate *e, const char *s) { (void)e; (void)s; return 0; }
int udev_enumerate_scan_devices(struct udev_enumerate *e) { (void)e; return 0; }
int udev_enumerate_scan_subsystems(struct udev_enumerate *e) { (void)e; return 0; }
struct udev_list_entry *udev_enumerate_get_list_entry(struct udev_enumerate *e) { (void)e; return NULL; }

/* ---- monitor (never fires; fd -1) ---- */
struct udev_monitor *udev_monitor_new_from_netlink(struct udev *u, const char *name) { (void)u; (void)name; return stub_alloc(); }
struct udev_monitor *udev_monitor_new_from_socket(struct udev *u, const char *path) { (void)u; (void)path; return stub_alloc(); }
struct udev_monitor *udev_monitor_ref(struct udev_monitor *m) { return stub_ref(m); }
struct udev_monitor *udev_monitor_unref(struct udev_monitor *m) { return stub_unref(m); }
struct udev *udev_monitor_get_udev(struct udev_monitor *m) { (void)m; return NULL; }
int udev_monitor_enable_receiving(struct udev_monitor *m) { (void)m; return 0; }
int udev_monitor_set_receive_buffer_size(struct udev_monitor *m, int size) { (void)m; (void)size; return 0; }
int udev_monitor_get_fd(struct udev_monitor *m) { (void)m; return -1; }
struct udev_device *udev_monitor_receive_device(struct udev_monitor *m) { (void)m; return NULL; }
int udev_monitor_filter_add_match_subsystem_devtype(struct udev_monitor *m, const char *s, const char *t) { (void)m; (void)s; (void)t; return 0; }
int udev_monitor_filter_add_match_tag(struct udev_monitor *m, const char *t) { (void)m; (void)t; return 0; }
int udev_monitor_filter_update(struct udev_monitor *m) { (void)m; return 0; }
int udev_monitor_filter_remove(struct udev_monitor *m) { (void)m; return 0; }

/* ---- queue ---- */
struct udev_queue *udev_queue_new(struct udev *u) { (void)u; return stub_alloc(); }
struct udev_queue *udev_queue_ref(struct udev_queue *q) { return stub_ref(q); }
struct udev_queue *udev_queue_unref(struct udev_queue *q) { return stub_unref(q); }
struct udev *udev_queue_get_udev(struct udev_queue *q) { (void)q; return NULL; }
int udev_queue_get_udev_is_active(struct udev_queue *q) { (void)q; return 0; }
int udev_queue_get_queue_is_empty(struct udev_queue *q) { (void)q; return 1; }
int udev_queue_get_seqnum_is_finished(struct udev_queue *q, unsigned long long int s) { (void)q; (void)s; return 1; }
int udev_queue_get_seqnum_sequence_is_finished(struct udev_queue *q, unsigned long long int a, unsigned long long int b) { (void)q; (void)a; (void)b; return 1; }
int udev_queue_get_fd(struct udev_queue *q) { (void)q; return -1; }
int udev_queue_flush(struct udev_queue *q) { (void)q; return 0; }

/* ---- hwdb (no properties) ---- */
struct udev_hwdb *udev_hwdb_new(struct udev *u) { (void)u; return stub_alloc(); }
struct udev_hwdb *udev_hwdb_ref(struct udev_hwdb *h) { return stub_ref(h); }
struct udev_hwdb *udev_hwdb_unref(struct udev_hwdb *h) { return stub_unref(h); }
struct udev_list_entry *udev_hwdb_get_properties_list_entry(struct udev_hwdb *h, const char *modalias, unsigned int flags) { (void)h; (void)modalias; (void)flags; return NULL; }
