#!/bin/sh
# Requires curl, nginx, and standard Debian utilities inside the container.
# Mount a dedicated writable directory at /var/lib/cloudflare and include
# trusted-proxies.conf from the HTTP context of the static Nginx configuration.
# This wrapper preserves nginx-proxy's original CMD and entrypoint.
set -eu
umask 077
LC_ALL=C
export LC_ALL

IPV4_URL='https://www.cloudflare.com/ips-v4'
IPV6_URL='https://www.cloudflare.com/ips-v6'
IPV4_PATTERN='[0-9]+(\.[0-9]+){3}/([1-9]|[12][0-9]|3[0-2])'
IPV6_PATTERN='[0-9A-Fa-f]*:[0-9A-Fa-f:]*/([1-9]|[1-9][0-9]|1[01][0-9]|12[0-8])'
DATA_DIR='/var/lib/cloudflare'
TRUST_FILE="$DATA_DIR/trusted-proxies.conf"
# A failed refresh may use a validated cache for up to seven days.
MAX_CACHE_AGE=604800
MAX_RESPONSE_BYTES=65536
work_dir=''

log() {
    printf '%s\n' "cloudflare-realip: $*" >&2
}

cleanup() {
    if [ -n "$work_dir" ]; then
        rm -f -- "$work_dir/ipv4.txt" "$work_dir/ipv6.txt" "$work_dir/candidate.conf" \
            "$work_dir/check.conf" "$work_dir/nginx.pid"
        rmdir -- "$work_dir"
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for tool in curl nginx mktemp date stat sed grep wc cat chmod mv rm rmdir; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "Required tool is missing: $tool"
        exit 1
    fi
done

# Provision this directory with the volume/image; do not accidentally write to
# an unrelated path or follow a symlink supplied as the cache file.
if [ ! -d "$DATA_DIR" ] || [ -L "$DATA_DIR" ] || [ -L "$TRUST_FILE" ]; then
    log "Expected a real directory at $DATA_DIR and a nonsymlink cache file."
    exit 1
fi

# The working files live on the destination filesystem for atomic replacement.
work_dir=$(mktemp -d "$DATA_DIR/.refresh.XXXXXX")
now=$(date +%s)
fetched_at_utc=$(date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ')
TIMESTAMP_PATTERN='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# Require at least one line and reject every unexpected byte, including NULs.
# -a prevents grep from treating binary input as an automatic match; errors
# also fail validation. Never silently discard malformed lines.
validate_lines() {
    grep -aEx "$1" "$2" >/dev/null || return 1
    if grep -aEvx "$1" "$2" >/dev/null; then
        return 1
    else
        [ "$?" -eq 1 ]
    fi
}

validate_config() {
    config_file=$1

    # Only our timestamp comment and fixed CIDR directives are permitted. This
    # gate runs BEFORE nginx reads the file, including when checking the cache.
    # Nginx then supplies the actual address and prefix validation.
    validate_lines "# fetched_at=$TIMESTAMP_PATTERN|set_real_ip_from ($IPV4_PATTERN|$IPV6_PATTERN);" \
        "$config_file" || return 1
    grep -aEq "^set_real_ip_from $IPV4_PATTERN;$" "$config_file" || return 1
    grep -aEq "^set_real_ip_from $IPV6_PATTERN;$" "$config_file" || return 1

    # Isolate validation from docker-gen output, certificates, and other config
    # that may not exist until the original entrypoint has initialized.
    cat > "$work_dir/check.conf" <<EOF
error_log stderr;
pid $work_dir/nginx.pid;
events {}
http {
    access_log off;
    include $config_file;
}
EOF
    nginx -t -q -c "$work_dir/check.conf"
}

fetch_list() {
    # -q ignores user curlrc files. No redirects, credentials, or insecure TLS.
    curl -q --fail --silent --show-error --proto '=https' \
        --connect-timeout 5 --max-time 15 --retry 2 --retry-max-time 45 \
        --max-filesize "$MAX_RESPONSE_BYTES" \
        --output "$2" "$1" || return 1
    [ "$(wc -c < "$2")" -le "$MAX_RESPONSE_BYTES" ] || return 1
    validate_lines "$3" "$2" || return 1
    [ "$(grep -ac '^' "$2")" -le 1024 ]
}

refresh() {
    # Both families must download and validate before replacing any saved data.
    fetch_list "$IPV4_URL" "$work_dir/ipv4.txt" "$IPV4_PATTERN" || return 1
    fetch_list "$IPV6_URL" "$work_dir/ipv6.txt" "$IPV6_PATTERN" || return 1

    printf '# fetched_at=%s\n' "$fetched_at_utc" > "$work_dir/candidate.conf" || return 1
    for list_file in "$work_dir/ipv4.txt" "$work_dir/ipv6.txt"; do
        # Handle a final line without a newline. Content has already passed the
        # byte-level checks; printf treats it solely as data, never shell code.
        while IFS= read -r cidr || [ -n "$cidr" ]; do
            printf 'set_real_ip_from %s;\n' "$cidr" \
                >> "$work_dir/candidate.conf" || return 1
        done < "$list_file"
    done
    [ "$(wc -c < "$work_dir/candidate.conf")" -le "$MAX_RESPONSE_BYTES" ] || return 1
    validate_config "$work_dir/candidate.conf" || return 1

    # Readable by Nginx workers; writable only by the owner. Timestamp and
    # directives are published together so a partial update cannot reset age.
    chmod 644 "$work_dir/candidate.conf" || return 1
    mv -f -- "$work_dir/candidate.conf" "$TRUST_FILE" || return 1
    log 'Updated the Cloudflare IPv4 and IPv6 trust list.'
}

use_cache() {
    [ -f "$TRUST_FILE" ] && [ ! -L "$TRUST_FILE" ] || return 1
    [ "$(stat -c %s "$TRUST_FILE")" -le "$MAX_RESPONSE_BYTES" ] || return 1
    cached_timestamp=$(sed -n '1s/^# fetched_at=//p' "$TRUST_FILE")
    printf '%s\n' "$cached_timestamp" | grep -Ex "$TIMESTAMP_PATTERN" >/dev/null || return 1
    fetched_at=$(date -u -d "$cached_timestamp" +%s) || return 1
    # Require an exact UTC timestamp, rather than date's more permissive inputs.
    [ "$(date -u -d "@$fetched_at" '+%Y-%m-%dT%H:%M:%SZ')" = "$cached_timestamp" ] || return 1
    # Reject future timestamps as well as expired caches.
    [ "$fetched_at" -le "$now" ] || return 1
    [ "$((now - fetched_at))" -le "$MAX_CACHE_AGE" ] || return 1
    validate_config "$TRUST_FILE" || return 1
    log 'Refresh failed; using the validated cache (less than seven days old).'
}

if ! refresh; then
    if ! use_cache; then
        log 'No recent, valid Cloudflare trust list is available; refusing startup.'
        exit 1
    fi
fi

cleanup
work_dir=''
trap - EXIT HUP INT TERM
exec /app/docker-entrypoint.sh "$@"
