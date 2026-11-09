#!/usr/bin/env bash
# Asynchronous build & push of the project Docker image for HPC (Apptainer) deployment.
#
# The image only contains the dependencies (code is bind-mounted), so it is tagged by a hash
# of the committed DEPS_FILES and only rebuilt when that tag is not in the registry yet.
# Builds run detached (systemd user unit, or setsid as a fallback), so git hooks return instantly.
#
# Naming follows the CI/CD of the base images (devidealab/amml-python-base):
#   repository  <IMAGE_NAME>-<hardware>[-slim]   (-slim if the Dockerfile's `version` is slim)
#   tags        deps-<hash>                      content of DEPS_FILES, used by hpc-pull.sh
#               <branch>, <branch>-<short sha>   branch and commit the image was built from
#               latest                           if built from the default branch
#
# Usage: .container/image.sh <command> [args]   (or `git image <command>` after `install`)
#   install              set up the git hooks and the `git image` alias (once per clone)
#   tag [<rev>]          print the deps tag and image references of a commit (default HEAD)
#   trigger [--force]    build & push the image for HEAD in the background, if needed
#   build <sha> [--branch <name>] [--force]
#                        run the build in the foreground (this is what the background job runs)
#   status               show the last build; exit code 0 = idle/success, 1 = failed/stopped, 3 = running
#   logs [-f]            show (or follow) the log of the last build
#   stop                 abort the running build
#   bump-base [<tag>] [--repo <repo>]
#                        pin the base image in the Dockerfile (default: the tag `latest` points to)
#   hook                 used by .githooks/*, cheap check + detached `trigger`
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
GIT_DIR=$(git rev-parse --absolute-git-dir)
STATE_DIR="$GIT_DIR/image-build"
STATUS_FILE="$STATE_DIR/status"
PUSHED_FILE="$STATE_DIR/pushed"
PID_FILE="$STATE_DIR/pid"
LOG_DIR="$STATE_DIR/logs"
SCRIPT="$REPO_ROOT/.container/image.sh"
UNIT="image-build-$(basename "$REPO_ROOT" | tr -c 'a-zA-Z0-9_.\n-' '-')"

# shellcheck source-path=SCRIPTDIR source=image.conf
source "$REPO_ROOT/.container/image.conf"
# shellcheck source=/dev/null
[[ -f "$REPO_ROOT/.container/image.local.conf" ]] && source "$REPO_ROOT/.container/image.local.conf"

REGISTRY=()  # extra `docker` args for registry access, set by registry_login

log() { printf '[image %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- Registry credentials ---

env_value() {  # <key> from .env (not sourced: it is also passed to the containers as env_file)
    [[ -f "$REPO_ROOT/.env" ]] || return 0
    sed -n "s/^$1=//p" "$REPO_ROOT/.env" | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

# Log in with DOCKERHUB_USERNAME/DOCKERHUB_TOKEN from .env into a private Docker config used only
# for registry access, so ~/.docker stays untouched. Without a token, the default `docker login` is used.
registry_login() {
    local user token
    user=$(env_value DOCKERHUB_USERNAME)
    token=$(env_value DOCKERHUB_TOKEN)
    if [[ -z $token ]]; then
        log "warning: DOCKERHUB_TOKEN is not set in .env, falling back to the default 'docker login' credentials"
        return 0
    fi
    [[ -n $user ]] || die "DOCKERHUB_TOKEN is set in .env, but DOCKERHUB_USERNAME is not"
    local config="$STATE_DIR/docker-auth"
    mkdir -p "$config"
    chmod 700 "$config"
    docker --config "$config" login -u "$user" --password-stdin <<<"$token" >/dev/null ||
        die "docker login as $user failed - check DOCKERHUB_TOKEN in .env"
    REGISTRY=(--config "$config")
    [[ ${IMAGE_NAME%%/*} == "$user" ]] ||
        log "warning: IMAGE_NAME ($IMAGE_NAME) is not in the namespace of DOCKERHUB_USERNAME ($user), pushing will likely be denied"
}

push_image() {  # <ref>
    local out="$STATE_DIR/push.out"
    docker "${REGISTRY[@]}" push "$1" 2>&1 | tee "$out" && return 0
    if grep -q 'denied' "$out"; then
        log "hint: DockerHub denied the push to ${1%:*}. Likely causes:"
        log "  - the repository does not exist yet and the access token may not create it:"
        log "    use a token with 'Read, Write, Delete' scope, or create the repository (public) on hub.docker.com once"
        log "  - the repository is private and the free plan's private repository limit is reached"
        log "  - DOCKERHUB_USERNAME/DOCKERHUB_TOKEN in .env do not belong to the '${IMAGE_NAME%%/*}' namespace"
    fi
    return 1
}

# --- Core: names, tags and registry state ---

# Keep deps_tag, image_version and image_repo in sync with .container/hpc-pull.sh
deps_tag() {  # <rev>
    local hash
    # shellcheck disable=SC2086  # DEPS_FILES is a word list
    hash=$(git -C "$REPO_ROOT" ls-tree -r "$1" -- $DEPS_FILES | sha256sum | cut -c1-12)
    echo "deps-$hash"
}

image_version() {  # <rev>: the default `ARG version` (full|slim) of the Dockerfile
    git -C "$REPO_ROOT" show "$1:Dockerfile" | sed -n 's/^ARG version="\{0,1\}\([a-z]*\).*/\1/p' | head -n 1
}

image_repo() {  # <hardware> <version>
    if [[ $2 == slim ]]; then echo "$IMAGE_NAME-$1-slim"; else echo "$IMAGE_NAME-$1"; fi
}

image_refs() {  # <rev>: the deps-tagged reference for every hardware
    local tag version hw
    tag=$(deps_tag "$1")
    version=$(image_version "$1")
    for hw in $HARDWARE; do echo "$(image_repo "$hw" "$version"):$tag"; done
}

docker_tag() {  # <name>: branch name as a valid Docker tag (like docker/metadata-action)
    echo "$1" | tr -c 'A-Za-z0-9_.\n-' '-' | sed 's/^[.-]*//' | cut -c1-128
}

default_branch() {
    local ref
    ref=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=origin/main
    echo "${ref#origin/}"
}

pushed_locally() { [[ -f "$PUSHED_FILE" ]] && grep -qxF "$1" "$PUSHED_FILE"; }

record_pushed() { mkdir -p "$STATE_DIR"; pushed_locally "$1" || echo "$1" >>"$PUSHED_FILE"; }

# Local record first, then the registry (records the result to avoid future network calls)
is_pushed() {  # <ref>
    pushed_locally "$1" && return 0
    docker "${REGISTRY[@]}" manifest inspect "$1" >/dev/null 2>&1 || return 1
    record_pushed "$1"
}

all_pushed() {  # <rev> [local-only]
    local ref
    for ref in $(image_refs "$1"); do
        if [[ ${2:-} == local-only ]]; then pushed_locally "$ref" || return 1
        else is_pushed "$ref" || return 1; fi
    done
}

# --- Status file (key=value lines) ---

status_get() { [[ -f "$STATUS_FILE" ]] && sed -n "s|^$1=||p" "$STATUS_FILE" || true; }

status_set() {
    if grep -q "^$1=" "$STATUS_FILE" 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" "$STATUS_FILE"
    else echo "$1=$2" >>"$STATUS_FILE"; fi
}

# --- Launchers ---

systemd_usable() {
    local launcher=${IMAGE_BUILD_LAUNCHER:-auto}
    [[ $launcher == setsid ]] && return 1
    command -v systemd-run >/dev/null || return 1
    # IDE git integrations and non-login SSH commands often lack these
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    case $(systemctl --user is-system-running 2>/dev/null) in running | degraded) ;; *) return 1 ;; esac
    [[ $launcher == systemd ]] && return 0
    # Without lingering, the user manager (and the build) dies with the last login session
    [[ $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null) == yes ]]
}

is_running() {
    case $(status_get launcher) in
        systemd) systemctl --user is-active --quiet "$UNIT" 2>/dev/null ;;
        setsid) [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

launch() {  # <log> <build args...>
    local logfile=$1
    shift
    if systemd_usable; then
        status_set launcher systemd
        local env=(--setenv=PATH="$PATH" --setenv=HOME="$HOME")
        local var
        for var in DOCKER_HOST DOCKER_CONFIG DOCKER_CONTEXT; do
            [[ -n ${!var:-} ]] && env+=(--setenv="$var=${!var}")
        done
        systemctl --user reset-failed "$UNIT" 2>/dev/null || true
        systemd-run --user --quiet --collect --unit="$UNIT" "${env[@]}" \
            -p RuntimeMaxSec="$MAX_RUNTIME" -p Nice=10 \
            -p StandardOutput="append:$logfile" -p StandardError="append:$logfile" \
            --working-directory="$REPO_ROOT" "$SCRIPT" build "$@" 9>&-
    else
        status_set launcher setsid
        # Not a process group leader (no job control), so setsid execs in place and $! is the session id
        # (9>&-: the worker must not inherit the trigger lock)
        setsid "$SCRIPT" build "$@" </dev/null >>"$logfile" 2>&1 9>&- &
        echo $! >"$PID_FILE"
    fi
}

stop_build() {  # <final state>
    case $(status_get launcher) in
        systemd) systemctl --user stop "$UNIT" ;;
        setsid)
            local pid
            pid=$(cat "$PID_FILE")
            kill -TERM -- "-$pid" 2>/dev/null || true
            for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
            kill -KILL -- "-$pid" 2>/dev/null || true
            ;;
    esac
    status_set state "$1"
    status_set finished "$(date -Is)"
}

# --- Commands ---

cmd_tag() {
    local rev=${1:-HEAD} ref
    deps_tag "$rev"
    for ref in $(image_refs "$rev"); do log "$ref"; done
}

cmd_hook() {
    # Runs synchronously inside git: only cheap local checks here, never fail
    [[ ${IMAGE_BUILD_DISABLE:-0} == 1 ]] && return 0
    [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]] && return 0  # post-rewrite follows
    all_pushed HEAD local-only && return 0
    if ! command -v docker >/dev/null; then
        log "docker not available here (devcontainer?), image build skipped - run '.container/image.sh trigger' on the host"
        return 0
    fi
    mkdir -p "$STATE_DIR"
    [[ -n $(env_value DOCKERHUB_TOKEN) ]] ||
        log "warning: DOCKERHUB_TOKEN is not set in .env, the push will only work if 'docker login' was done on this machine"
    log "image $(deps_tag HEAD) not known to be pushed, checking/building in background - see '.container/image.sh status'"
    setsid -f "$SCRIPT" trigger </dev/null >>"$STATE_DIR/trigger.log" 2>&1
}

cmd_trigger() {
    local force=0 sha tag branch logfile
    [[ ${1:-} == --force ]] && force=1
    [[ -n $IMAGE_NAME ]] || die "IMAGE_NAME is not set in .container/image.conf"
    docker info >/dev/null 2>&1 || die "docker daemon not reachable"
    sha=$(git rev-parse HEAD)
    tag=$(deps_tag "$sha")
    branch=$(git symbolic-ref --quiet --short HEAD) || branch=""
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    registry_login

    exec 9>"$STATE_DIR/lock"
    flock 9
    if is_running; then
        if [[ $(status_get tag) == "$tag" ]]; then
            log "build of $tag already running"
            return 0
        fi
    fi
    if [[ $force == 0 ]] && all_pushed "$sha"; then
        log "already pushed: $(image_refs "$sha" | tr '\n' ' ')"
        return 0
    fi
    if is_running; then
        log "superseding running build of $(status_get tag)"
        stop_build superseded
    fi

    logfile="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$tag.log"
    ln -sfn "$(basename "$logfile")" "$LOG_DIR/latest.log"
    local old=("$LOG_DIR"/2*.log)  # timestamped names sort chronologically; keep the last 20
    ((${#old[@]} > 20)) && rm -f "${old[@]:0:${#old[@]}-20}"
    printf 'state=queued\ntag=%s\ncommit=%s\nbranch=%s\nstarted=%s\nlog=%s\n' \
        "$tag" "$sha" "$branch" "$(date -Is)" "$logfile" >"$STATUS_FILE"
    local args=("$sha")
    [[ -n $branch ]] && args+=(--branch "$branch")
    [[ $force == 1 ]] && args+=(--force)
    launch "$logfile" "${args[@]}"
    log "started build of $tag ($(status_get launcher)), log: $logfile"
}

cmd_build() {
    local sha=${1:?usage: build <sha> [--branch <name>] [--force]} branch="" force=0 tag version hw repo ref tags
    shift
    while (($#)); do
        case $1 in
            --branch) branch=$2; shift 2 ;;
            --force) force=1; shift ;;
            *) die "unknown build argument '$1'" ;;
        esac
    done
    tag=$(deps_tag "$sha")
    version=$(image_version "$sha")
    BUILD_TAG=$tag  # global: the EXIT trap runs after the locals are gone
    mkdir -p "$STATE_DIR"
    echo $$ >"$PID_FILE"

    # Only touch the status if it still describes this build (it may have been superseded)
    own_status() { [[ $(status_get tag) == "$BUILD_TAG" ]] && status_set "$@"; }
    # shellcheck disable=SC2329  # invoked via trap
    finish() {
        local rc=$?
        if [[ $(status_get state) == running ]]; then
            own_status state "$([[ $rc == 0 ]] && echo success || echo failed)" || true
            own_status finished "$(date -Is)" || true
        fi
        log "exit code $rc"
    }
    trap finish EXIT
    trap 'exit 143' TERM

    own_status state running || true
    registry_login
    log "building $tag ($version) from commit $sha${branch:+ on $branch} for hardware: $HARDWARE"
    for hw in $HARDWARE; do
        repo=$(image_repo "$hw" "$version")
        ref="$repo:$tag"
        if [[ $force == 0 ]] && is_pushed "$ref"; then
            log "$ref already pushed, skipping"
            continue
        fi
        tags=("$ref")
        if [[ -n $branch ]]; then
            tags+=("$repo:$(docker_tag "$branch")" "$repo:$(docker_tag "$branch")-${sha:0:7}")
            [[ $branch == "$(default_branch)" ]] && tags+=("$repo:latest")
        fi
        log "docker build ${tags[*]}"
        # Build from the committed snapshot, not the working tree
        # shellcheck disable=SC2086  # BUILD_ARGS is a word list
        git -C "$REPO_ROOT" archive --format=tar "$sha" |
            docker build --progress=plain -f Dockerfile --build-arg hardware="$hw" --build-arg version="$version" \
                $BUILD_ARGS --label org.opencontainers.image.revision="$sha" "${tags[@]/#/--tag=}" -
        for ref in "${tags[@]}"; do
            log "docker push $ref"
            push_image "$ref"
        done
        record_pushed "${tags[0]}"
    done
    log "done: $tag"
}

cmd_status() {
    local state
    echo "HEAD deps tag: $(deps_tag HEAD) ($(all_pushed HEAD local-only && echo pushed || echo 'not pushed or unknown'))"
    if [[ ! -f "$STATUS_FILE" ]]; then
        echo "no build so far"
        return 0
    fi
    state=$(status_get state)
    if [[ $state == running || $state == queued ]] && ! is_running; then
        state="$state (process gone - killed?)"
        status_set state failed
    fi
    echo "last build:    $(status_get tag) [$state]"
    echo "commit:        $(status_get commit) $(status_get branch)"
    echo "launcher:      $(status_get launcher)"
    echo "started:       $(status_get started)"
    echo "finished:      $(status_get finished)"
    echo "log:           $(status_get log)"
    if is_running; then
        [[ $(status_get launcher) == systemd ]] && systemctl --user status "$UNIT" --no-pager -n 0 || true
        return 3
    fi
    [[ $(status_get state) == success ]]
}

cmd_logs() {
    local logfile="$LOG_DIR/latest.log"
    [[ -e $logfile ]] || die "no build log yet"
    if [[ ${1:-} == -f ]]; then tail -n 50 -F "$logfile"; else cat "$logfile"; fi
}

cmd_stop() {
    exec 9>"$STATE_DIR/lock"
    flock 9
    is_running || { log "no build running"; return 0; }
    stop_build stopped
    log "stopped build of $(status_get tag)"
}

cmd_install() {
    git -C "$REPO_ROOT" config core.hooksPath .githooks
    git -C "$REPO_ROOT" config alias.image '!.container/image.sh'
    log "hooks installed (core.hooksPath=.githooks), 'git image <command>' available"
    if systemd_usable; then log "launcher: systemd user unit $UNIT"
    else log "launcher: setsid (for systemd, run 'loginctl enable-linger' or set IMAGE_BUILD_LAUNCHER=systemd)"; fi
    [[ -n $(docker info --format '{{.IndexServerAddress}}' 2>/dev/null) ]] || log "warning: docker not reachable"
    if [[ -n $(env_value DOCKERHUB_TOKEN) ]]; then
        registry_login && log "logged in to DockerHub as $(env_value DOCKERHUB_USERNAME) (token from .env)"
    elif ! grep -qs '"auths"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json"; then
        log "warning: no registry credentials, set DOCKERHUB_USERNAME/DOCKERHUB_TOKEN in .env"
    fi
}

cmd_bump_base() {
    local tag="" base digest candidate hw suffix=""
    base=$(sed -n 's/^ARG base_repo="\(.*\)"/\1/p' "$REPO_ROOT/Dockerfile")
    while (($#)); do
        case $1 in
            --repo) base=$2; shift 2 ;;
            *) tag=$1; shift ;;
        esac
    done
    [[ -n $base ]] || die "no 'ARG base_repo' in the Dockerfile"
    [[ $(image_version HEAD) == slim ]] && suffix=-slim
    if [[ -z $tag ]]; then
        digest=$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$base-cpu:latest")
        for candidate in $(curl -fsS "https://hub.docker.com/v2/repositories/$base-cpu/tags?page_size=25&ordering=last_updated" |
            grep -o '"name":"main-[^"]*"' | cut -d'"' -f4); do
            if [[ $(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$base-cpu:$candidate") == "$digest" ]]; then
                tag=$candidate
                break
            fi
        done
        [[ -n $tag ]] || die "no main-* tag matches $base-cpu:latest ($digest)"
    fi
    for hw in $HARDWARE; do
        docker buildx imagetools inspect "$base-$hw$suffix:$tag" >/dev/null 2>&1 ||
            die "$base-$hw$suffix:$tag does not exist"
    done
    sed -i "s|^ARG base_repo=.*|ARG base_repo=\"$base\"|; s|^ARG base_tag=.*|ARG base_tag=\"$tag\"|" "$REPO_ROOT/Dockerfile"
    log "base image pinned to $base:$tag - commit the Dockerfile to rebuild the image"
}

command=${1:-status}
shift || true
case $command in
    install | tag | hook | trigger | build | status | logs | stop) "cmd_$command" "$@" ;;
    bump-base) cmd_bump_base "$@" ;;
    -h | --help | help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
    *) die "unknown command '$command' (see --help)" ;;
esac
