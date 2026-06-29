package kubernetes.admission

import future.keywords.contains
import future.keywords.if

# ────────────────────────────────────────────────────
# DENY: Images from unauthorized registries
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    image := container.image
    not startswith(image, "ghcr.io/radix-hft/")
    not startswith(image, "alpine:")
    not startswith(image, "postgres:")
    msg := sprintf("Image %v not from allowed registry (ghcr.io/radix-hft)", [image])
}

# ────────────────────────────────────────────────────
# DENY: Privileged containers
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    container.securityContext.privileged == true
    msg := sprintf("Privileged container %v not allowed in trading namespace", [container.name])
}

# ────────────────────────────────────────────────────
# DENY: Missing resource requests/limits
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    not container.resources.requests.cpu
    msg := sprintf("Container %v missing CPU request", [container.name])
}

deny[msg] if {
    container := input.request.object.spec.containers[_]
    not container.resources.requests.memory
    msg := sprintf("Container %v missing memory request", [container.name])
}

deny[msg] if {
    container := input.request.object.spec.containers[_]
    not container.resources.limits.cpu
    msg := sprintf("Container %v missing CPU limit", [container.name])
}

deny[msg] if {
    container := input.request.object.spec.containers[_]
    not container.resources.limits.memory
    msg := sprintf("Container %v missing memory limit", [container.name])
}

# ────────────────────────────────────────────────────
# DENY: Running as root
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    container.securityContext.runAsUser == 0
    msg := sprintf("Container %v cannot run as root (UID 0)", [container.name])
}

# ────────────────────────────────────────────────────
# DENY: Writable root filesystem
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    container.securityContext.readOnlyRootFilesystem != true
    msg := sprintf("Container %v must have readOnlyRootFilesystem=true", [container.name])
}

# ────────────────────────────────────────────────────
# DENY: Missing liveness/readiness probes
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    not container.livenessProbe
    msg := sprintf("Container %v missing livenessProbe", [container.name])
}

deny[msg] if {
    container := input.request.object.spec.containers[_]
    not container.readinessProbe
    msg := sprintf("Container %v missing readinessProbe", [container.name])
}

# ────────────────────────────────────────────────────
# DENY: Missing Pod Security labels
# ────────────────────────────────────────────────────
deny[msg] if {
    input.request.object.metadata.labels["app.kubernetes.io/name"] == ""
    msg := "Missing required label: app.kubernetes.io/name"
}

deny[msg] if {
    input.request.object.metadata.labels["app.kubernetes.io/version"] == ""
    msg := "Missing required label: app.kubernetes.io/version"
}

# ────────────────────────────────────────────────────
# DENY: Node affinity not configured in production
# ────────────────────────────────────────────────────
deny[msg] if {
    input.request.namespace == "trading"
    not input.request.object.spec.nodeSelector
    not input.request.object.spec.affinity
    msg := "Pods in trading namespace require nodeSelector or affinity"
}

# ────────────────────────────────────────────────────
# DENY: Requests larger than node capacity
# ────────────────────────────────────────────────────
deny[msg] if {
    container := input.request.object.spec.containers[_]
    cpu_request := parse_resource(container.resources.requests.cpu)
    cpu_request > 4
    msg := sprintf("Container CPU request %v exceeds node limit (4 cores)", [cpu_request])
}

# ────────────────────────────────────────────────────
# WARN: High resource requests (audit only)
# ────────────────────────────────────────────────────
warn[msg] if {
    container := input.request.object.spec.containers[_]
    memory_limit := parse_memory(container.resources.limits.memory)
    memory_limit > 8 * 1024  # > 8GB
    msg := sprintf("Container memory limit %v is unusually high", [memory_limit])
}

# ────────────────────────────────────────────────────
# Helper functions
# ────────────────────────────────────────────────────

# Parse CPU requests (supports millicores: 100m, cores: 1, 2.5)
parse_resource(res) = value if {
    endswith(res, "m")
    value := to_number(trim_suffix(res, "m")) / 1000
} else = value if {
    value := to_number(res)
}

# Parse memory (supports Ki, Mi, Gi)
parse_memory(mem) = value if {
    endswith(mem, "Gi")
    value := to_number(trim_suffix(mem, "Gi")) * 1024
} else = value if {
    endswith(mem, "Mi")
    value := to_number(trim_suffix(mem, "Mi"))
} else = value if {
    endswith(mem, "Ki")
    value := to_number(trim_suffix(mem, "Ki")) / 1024
} else = value if {
    value := to_number(mem)
}

# ────────────────────────────────────────────────────
# Testing
# ────────────────────────────────────────────────────

test_deny_privileged if {
    deny["Privileged container test_container not allowed"] with input as {
        "request": {
            "object": {
                "spec": {
                    "containers": [{
                        "name": "test_container",
                        "securityContext": {"privileged": true}
                    }]
                }
            }
        }
    }
}

test_deny_missing_requests if {
    deny["Container test_container missing CPU request"] with input as {
        "request": {
            "object": {
                "spec": {
                    "containers": [{
                        "name": "test_container",
                        "resources": {
                            "requests": {"memory": "128Mi"},
                            "limits": {"cpu": "1", "memory": "256Mi"}
                        }
                    }]
                }
            }
        }
    }
}

test_parse_resource if {
    parse_resource("500m") == 0.5
    parse_resource("2") == 2
    parse_resource("1.5") == 1.5
}

test_parse_memory if {
    parse_memory("512Mi") == 512
    parse_memory("2Gi") == 2048
    parse_memory("1024Ki") == 1
}
