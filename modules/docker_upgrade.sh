# Sourcing logging library
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGER_SH="$BASE_DIR/modules/logger.sh"
if [ -f "$LOGGER_SH" ]; then
    # shellcheck disable=SC1090
    source "$LOGGER_SH"
fi

upgrade_docker_replica_set() {
    local target_ver="$1"
    local is_rollback=false
    if [[ "${2:-}" == "rollback" ]]; then
        is_rollback=true
    fi

    # Ensure docker-compose configuration file exists
    if [[ ! -f "${COMPOSE_FILE:-}" ]]; then
        log_error "COMPOSE_FILE not found: ${COMPOSE_FILE:-}"
        exit 1
    fi

    # 1. Detect the current Docker image version from docker-compose.yml
    local current_ver
    current_ver=$(grep -i 'image:' "$COMPOSE_FILE" | head -n 1 | awk -F'mongo:' '{print $2}' | tr -d ' "\r\n')
    
    log_info "Current Docker Image : mongo:${current_ver:-unknown}"
    log_info "Target Docker Image : mongo:${target_ver}"

    # 2. Update the Docker Compose configuration automatically in-place
    sed -i "s|\(image:[[:space:]]*mongo:\).*|\1${target_ver}|g" "$COMPOSE_FILE"

    # 3. Pull the new image
    log_info "Pulling image..."
    if ! docker compose -f "$COMPOSE_FILE" pull; then
        log_error "Failed to pull mongo:${target_ver} image."
        exit 1
    fi

    # 4. We must construct auth arguments for status queries
    local auth_args=""
    if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
        auth_args="-u $MONGO_ADMIN_USER -p $MONGO_ADMIN_PASS --authenticationDatabase $MONGO_AUTH_DB"
    fi

    # 5. Perform Zero-Downtime Rolling Upgrade of the replica set nodes
    log_info "Starting Rolling Upgrade of Replica Set nodes..."

    # Find the current PRIMARY node before we start upgrading
    local initial_primary
    initial_primary=$(get_primary_node || echo "")

    local nodes_to_upgrade=()
    local primary_node=""

    if [ -n "$initial_primary" ]; then
        primary_node="$initial_primary"
        log_info "Active PRIMARY node identified: $primary_node"
        
        # We upgrade secondaries first to maintain quorum and primary availability
        for c in "${MONGO1:-mongo1}" "${MONGO2:-mongo2}" "${MONGO3:-mongo3}"; do
            if [ "$c" != "$primary_node" ]; then
                nodes_to_upgrade+=("$c")
            fi
        done
        # Add primary at the end of the upgrade list
        nodes_to_upgrade+=("$primary_node")
    else
        log_warn "No active PRIMARY node detected. Performing sequential upgrade."
        nodes_to_upgrade=("${MONGO1:-mongo1}" "${MONGO2:-mongo2}" "${MONGO3:-mongo3}")
    fi

    # Upgrade nodes one by one
    for node in "${nodes_to_upgrade[@]}"; do
        # If this node is the active primary, step it down first to avoid election interruptions
        if [ "$node" = "$primary_node" ] && [ -n "$primary_node" ]; then
            log_info "Stepping down PRIMARY node $primary_node to elect a new primary..."
            docker exec "$primary_node" mongosh $auth_args --quiet --eval "try { rs.stepDown(60); } catch(e) {}" 2>/dev/null || true
            sleep 5
        fi

        # If this is a rollback/downgrade, we must clear the node's data volume to allow initial sync.
        # Otherwise, the container will crash due to WiredTiger storage engine version mismatches.
        if [ "$is_rollback" = true ]; then
            log_info "Rollback detected: Stopping node $node and clearing its data volume..."
            docker compose -f "$COMPOSE_FILE" stop "$node" >/dev/null 2>&1 || true
            docker compose -f "$COMPOSE_FILE" run --rm --entrypoint "sh -c 'find /data/db -mindepth 1 -delete'" "$node" >/dev/null 2>&1 || true
        fi

        log_info "Recreating container: $node..."
        if ! docker compose -f "$COMPOSE_FILE" up -d --no-deps "$node"; then
            log_error "Failed to recreate container: $node"
            exit 1
        fi

        log_info "Waiting for node $node to join replica set and become healthy..."
        if ! wait_for_node_healthy "$node"; then
            exit 1
        fi
    done

    # 6. Verify final replica set status and retrieve the active PRIMARY node name
    log_info "Finalizing and waiting for PRIMARY..."
    local query_node="${MONGO_QUERY_NODE:-${MONGO1:-mongo1}}"
    local timeout=90
    local elapsed=0
    local replica_healthy=false
    local detected_primary=""

    while [ $elapsed -lt $timeout ]; do
        local check_res=""
        check_res=$(docker exec "$query_node" mongosh $auth_args --quiet --eval "
            try {
                const status = rs.status();
                if (status.ok === 1) {
                    const members = status.members;
                    const primary = members.find(m => m.state === 1 || m.stateStr === 'PRIMARY');
                    const secondaries = members.filter(m => m.state === 2 || m.stateStr === 'SECONDARY');
                    const unhealthy = members.filter(m => m.health !== 1);
                    if (primary && secondaries.length === 2 && unhealthy.length === 0) {
                        print('REPLICA_OK:' + primary.name.split(':')[0]);
                    } else {
                        print('PENDING');
                    }
                } else {
                    print('PENDING');
                }
            } catch (e) {
                print('PENDING');
            }
        " 2>/dev/null || true)
        check_res=$(echo "$check_res" | tr -d '\r\n[:space:]')

        if [[ "$check_res" == *"REPLICA_OK"* ]]; then
            replica_healthy=true
            detected_primary=$(echo "$check_res" | awk -F'REPLICA_OK:' '{print $2}')
            break
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$replica_healthy" = false ]; then
        log_error "Replica set did not stabilize/elect a PRIMARY within $timeout seconds."
        exit 1
    fi

    log_success "Replica upgraded successfully."
    
    # Export PRIMARY_NODE so caller scripts can use it (e.g. for final FCV commands)
    PRIMARY_NODE="$detected_primary"
}

get_primary_node() {
    # We construct auth arguments
    local auth_args=""
    if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
        auth_args="-u $MONGO_ADMIN_USER -p $MONGO_ADMIN_PASS --authenticationDatabase $MONGO_AUTH_DB"
    fi

    # Find running containers
    local running_nodes=()
    for c in "${MONGO1:-mongo1}" "${MONGO2:-mongo2}" "${MONGO3:-mongo3}"; do
        if docker ps --format '{{.Names}}' | grep -qx "$c"; then
            running_nodes+=("$c")
        fi
    done

    if [ "${#running_nodes[@]}" -eq 0 ]; then
        return 1
    fi

    # Try to find the PRIMARY from any running node
    for node in "${running_nodes[@]}"; do
        local primary=""
        primary=$(docker exec "$node" mongosh $auth_args --quiet --eval "
            try {
                const status = rs.status();
                if (status.ok === 1) {
                    const p = status.members.find(m => m.state === 1 || m.stateStr === 'PRIMARY');
                    if (p && p.name) {
                        print(p.name.split(':')[0]);
                    }
                }
            } catch (e) {}
        " 2>/dev/null || true)
        primary=$(echo "$primary" | tr -d '\r\n[:space:]')
        
        if [ -n "$primary" ]; then
            echo "$primary"
            return 0
        fi
    done

    # Fallback: if we couldn't query rs.status(), but a single node is running, it might not be in a replica set or election is ongoing.
    # In that case, we can return the first running node as fallback.
    echo "${running_nodes[0]}"
    return 0
}

wait_for_node_healthy() {
    local node="$1"
    local timeout=90
    local elapsed=0
    local node_ok=false

    # We determine a query node that is currently running and NOT the one being upgraded
    local query_node=""
    for c in "${MONGO1:-mongo1}" "${MONGO2:-mongo2}" "${MONGO3:-mongo3}"; do
        if [ "$c" != "$node" ]; then
            if docker ps --format '{{.Names}}' | grep -qx "$c"; then
                query_node="$c"
                break
            fi
        fi
    done

    # If no other running nodes are found, query the node itself
    if [ -z "$query_node" ]; then
        query_node="$node"
    fi

    # Construct auth arguments
    local auth_args=""
    if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
        auth_args="-u $MONGO_ADMIN_USER -p $MONGO_ADMIN_PASS --authenticationDatabase $MONGO_AUTH_DB"
    fi

    while [ $elapsed -lt $timeout ]; do
        local check_res=""
        check_res=$(docker exec "$query_node" mongosh $auth_args --quiet --eval "
            try {
                const status = rs.status();
                if (status.ok === 1) {
                    const m = status.members.find(member => member.name.split(':')[0] === '$node');
                    if (m && m.health === 1 && (m.state === 1 || m.state === 2)) {
                        print('OK');
                    } else {
                        print('PENDING');
                    }
                } else {
                    print('PENDING');
                }
            } catch (e) {
                print('PENDING');
            }
        " 2>/dev/null || true)
        check_res=$(echo "$check_res" | tr -d '\r\n[:space:]')

        if [ "$check_res" = "OK" ]; then
            node_ok=true
            break
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$node_ok" = false ]; then
        log_error "Node $node did not become healthy in replica set within $timeout seconds."
        return 1
    fi
    return 0
}
