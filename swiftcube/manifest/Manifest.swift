// SPDX-License-Identifier: Apache-2.0
// Manifest.swift — the typed SwiftCube manifest + its mapping onto cubestore objects (SC9).
//
// A manifest (SWIFTCUBE_DESIGN §10) is the human-facing desired state `sctl apply` submits. The
// parser (ManifestParser.swift) turns YAML into this `Manifest`; this file holds the typed shape
// and the one-way mapping onto the objects the existing reconcilers already consume:
//
//   Manifest ──▶ DeploymentSpec   at /apps/<app>/spec      (SC4 scheduler)
//            ──▶ ServiceExpose     at /expose/<service>     (SC6 LB programmer, when exposed via lb)
//            ──▶ ServiceSpec       at /svcspec/<service>    (SC7 east-west registry)
//
// So a single `apply` wires the whole apply→schedule→run→ready→endpoint→LB/east-west pipeline that
// SC3–SC7 already implement — SC9 only adds the human entry point and validation on top.
//
// These structs are **Foundation-free** and shared with the server: `sctld` re-validates a
// submitted manifest by parsing it through the same code, so a malformed manifest is rejected
// both at the CLI and at the controller. Typing/validation (resource units, ports, capability
// syntax, the strategy block) is the parser's job; this file is the typed result + the mapping.
//
// Mapping decisions worth recording (also in FORMAT.md):
//   • The manifest's single `resources:` block maps to BOTH the scheduling request and the Cell's
//     enforced limit (request == limit in v1); a separate `limits:` block is a later seam.
//   • `image: registry.local/app@<algo>:<hex>` carries a content digest only. The detached image
//     SIGNATURE is staged by the registry (the image-registry seam, out of scope for SC9), so the
//     mapped `ImageRef.signature` is empty here and verified once a registry stages it.
//   • The rollout `revision` is NOT set here — `sctl apply` assigns it (bump on a template change,
//     keep it on a pure scale), since revision identity is an apply-time concern (SC9b consumes it).

// MARK: - Update strategy

/// Which rollout strategy a revision change uses. The rolling/blue-green/canary *state machine* is
/// SC9b; SC9 parses, validates, and carries the block so apply records it for the controller.
enum RolloutStrategy: UInt8, Equatable {
    case rolling   = 0
    case blueGreen = 1
    case canary    = 2
}

/// The `update:` block. `maxSurge`/`maxUnavailable` apply to rolling; `canaryStepPercents` is the
/// canary weight ramp (e.g. [10, 50, 100]); `progressDeadlineSeconds` is the rollback window the
/// SC9b state machine arms. Fields not relevant to the chosen strategy keep their defaults.
struct UpdateStrategy: Equatable {
    var strategy: RolloutStrategy = .rolling
    var maxSurge: UInt32 = 1
    var maxUnavailable: UInt32 = 0
    var canaryStepPercents: [UInt32] = []
    var progressDeadlineSeconds: UInt32 = 600
}

// MARK: - Sub-objects

/// A content-addressed image reference parsed from `registry.local/app@<algo>:<hex>`.
struct ManifestImage: Equatable {
    var reference: String       // the full ref as written, for display/registry resolution
    var algorithm: String       // e.g. "sha256" / "blake3" (the registry's CAS algo)
    var digest: [UInt8]         // the decoded 32-byte content address
}

/// The scheduling/enforcement resources (`cpu`/`memory`), already normalized to millicpu + bytes.
struct ManifestResources: Equatable {
    var cpuMillis: UInt32
    var memBytes: UInt64
}

/// One named port and its optional external exposure (`expose:` block).
struct ManifestPort: Equatable {
    var name: String
    var container: UInt16
    var expose: ManifestExpose?
}

/// The `expose:` block on a port: how an external LB fronts this port.
struct ManifestExpose: Equatable {
    var via: String             // "lb" (the only sink in v1)
    var provider: String        // "nginx" | "hetzner" | "aws"
    var listen: UInt16          // the LB's listen port (e.g. 443)
    var proto: ListenProtocol   // http/https/tcp
    var tlsCertRef: String      // https only; "" otherwise (secrets seam)
}

/// One volume request (`volumes:` entry) → a node-local sticky PV (SC8).
struct ManifestVolume: Equatable {
    var name: String
    var mount: String
    var persistent: Bool
    var sizeBytes: UInt64
}

/// The `health:` block: a readiness and a liveness probe (already typed as SC5 `ProbeSpec`s).
struct ManifestHealth: Equatable {
    var readiness: ProbeSpec = ProbeSpec()
    var liveness: ProbeSpec = ProbeSpec()
}

/// The `placement:` block.
struct ManifestPlacement: Equatable {
    var spread: String = "node"     // recorded; the scheduler already spreads by node
    var nodeSelector: [String] = [] // "key=value" labels required of a node
    var pinHint: String = ""        // SC8 sticky-PV seam
}

// MARK: - Manifest

struct Manifest: Equatable {
    var app: String
    var image: ManifestImage
    var replicas: UInt32
    var command: [String]
    var update: UpdateStrategy
    var resources: ManifestResources
    var ports: [ManifestPort]
    var env: [String]               // "KEY=VALUE", in document order
    var secrets: [String]
    var volumes: [ManifestVolume]
    var capabilities: [String]
    var health: ManifestHealth
    var placement: ManifestPlacement
    var namespaceRoot: String = "/"
    var tmpfsScratch: Bool = true
    var restartPolicy: RestartPolicy = .always

    /// The primary container port (first declared) — the endpoint port the Cell exposes and the
    /// east-west service port. 0 if no ports are declared.
    var primaryPort: UInt16 { ports.first?.container ?? 0 }

    /// The first port carrying an `expose:` block, if any (the LB-fronted port).
    var exposedPort: ManifestPort? {
        for p in ports where p.expose != nil { return p }
        return nil
    }
}

// MARK: - Mapping → cubestore objects

extension Manifest {
    /// The Cell template (everything a Cell needs except per-instance identity + node). The
    /// manifest `resources` is used as the enforced limit; the scheduling request is the same.
    func cellTemplate() -> CellTemplate {
        let limit = ResourceLimits(cpuMillis: resources.cpuMillis, memBytes: resources.memBytes)
        var vol: VolumeMount? = nil
        if let v = volumes.first(where: { $0.persistent }) {
            vol = VolumeMount(name: v.name, mountPath: v.mount, handleSlot: 0, sizeBytes: v.sizeBytes)
        }
        return CellTemplate(image: imageRef(), capabilities: capabilities, resources: limit,
                            namespaceRoot: namespaceRoot, args: command, env: env,
                            tmpfsScratch: tmpfsScratch, volume: vol, restartPolicy: restartPolicy)
    }

    /// The image reference as an SC3 `ImageRef`. Signature is empty (registry seam — see header).
    func imageRef() -> ImageRef { ImageRef(digest: image.digest, signature: []) }

    /// The full `DeploymentSpec` written to /apps/<app>/spec. `revision` is assigned by the caller
    /// (`sctl apply`): a template change bumps it; a pure scale keeps it.
    func toDeployment(revision: UInt64) -> DeploymentSpec {
        let request = ResourceLimits(cpuMillis: resources.cpuMillis, memBytes: resources.memBytes)
        var template = cellTemplate()
        // Thread the SC5 service/port/probe section onto the template so the scheduler's
        // materialize() carries it to every replica's CellSpec (service = app for now).
        template.service = app
        template.port = primaryPort
        template.readiness = health.readiness
        template.liveness = health.liveness
        return DeploymentSpec(app: app, replicas: replicas, revision: revision, request: request,
                              nodeSelector: placement.nodeSelector, pinHint: placement.pinHint,
                              template: template)
    }

    /// The east-west service registration written to /svcspec/<app>.
    func toServiceSpec() -> ServiceSpec {
        ServiceSpec(name: app, selector: app, servicePort: primaryPort)
    }

    /// The LB exposure written to /expose/<app>, or nil when no port is exposed via an LB.
    func toExpose() -> ServiceExpose? {
        guard let port = exposedPort, let ex = port.expose, ex.via == "lb" else { return nil }
        let health = healthForExpose(containerPort: port.container)
        return ServiceExpose(service: app, provider: ex.provider, listenPort: ex.listen,
                             proto: ex.proto, tlsCertRef: ex.tlsCertRef,
                             healthPath: health.path, healthPort: health.port)
    }

    /// The LB health check derived from the readiness probe (an http path ⇒ active-ish passive
    /// health; otherwise a TCP connect check on the container port).
    private func healthForExpose(containerPort: UInt16) -> (path: String, port: UInt16) {
        if health.readiness.kind == .http {
            let p = health.readiness.port == 0 ? containerPort : health.readiness.port
            return (health.readiness.httpPath, p)
        }
        return ("", containerPort)
    }
}
