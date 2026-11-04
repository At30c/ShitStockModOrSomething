#!/usr/bin/env bash

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "y2s" && "$TARGET_CODENAME" != "y2slte" ]]; then
    return 0
fi

# A failed/older build may have left the two paths in the generated context
# file without their SELinux type.  Remove only those stale entries so
# ADD_TO_WORK_DIR can write the complete path/context pair below.
for STALE_CONTEXTS in \
    "$WORK_DIR/configs/file_context-vendor" \
    "$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"; do
    if [ -f "$STALE_CONTEXTS" ]; then
        sed -i -E \
            -e '\#^/vendor/bin/graphics_allocator_trace[[:space:]]*$#d' \
            -e '\#^/vendor/etc/init/graphics_allocator_trace\\.rc[[:space:]]*$#d' \
            -e '\#^/(vendor|system/vendor)/bin/graphics_allocator_trace[[:space:]]*$#d' \
            -e '\#^/(vendor|system/vendor)/etc/init/graphics_allocator_trace\\.rc[[:space:]]*$#d' \
            "$STALE_CONTEXTS"
    fi
done

# An incremental run may also retain the generic 0644 fs_config entries that
# were generated when the whole vendor/ directory was copied automatically.
# Remove only these two records so the explicit modes below are authoritative.
if [ -f "$WORK_DIR/configs/fs_config-vendor" ]; then
    sed -i -E \
        -e '\#^vendor/bin/graphics_allocator_trace[[:space:]].*$#d' \
        -e '\#^vendor/etc/init/graphics_allocator_trace\.rc[[:space:]].*$#d' \
        "$WORK_DIR/configs/fs_config-vendor"
fi

ADD_TO_WORK_DIR "$MODPATH" "vendor" "bin/graphics_allocator_trace" \
    0 0 755 "u:object_r:vendor_shell_exec:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" "etc/init/graphics_allocator_trace.rc" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
grep -q -F 'graphics_allocator_trace' "$VENDOR_FILE_CONTEXTS" || {
    cat >> "$VENDOR_FILE_CONTEXTS" <<'EOF'
/(vendor|system/vendor)/bin/graphics_allocator_trace u:object_r:vendor_shell_exec:s0
/(vendor|system/vendor)/etc/init/graphics_allocator_trace\.rc u:object_r:vendor_configs_file:s0
EOF
}
unset VENDOR_FILE_CONTEXTS
