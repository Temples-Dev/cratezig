# Networking

The networking subsystem manages virtual networks, IP assignment, and the plumbing that connects containers to each other and to the outside world.

---

## Network Drivers

| Driver | Description | Default |
|--------|-------------|---------|
| `bridge` | Linux bridge (`docker0`), containers on same host communicate | Yes |
| `host` | Container shares host network stack, no isolation | No |
| `none` | Loopback only, complete network isolation | No |
| `overlay` | Multi-host networking (Swarm), uses VXLAN | No |
| `macvlan` | Container gets a MAC address on the physical network | No |
| `ipvlan` | Like macvlan but shares MAC, uses IP routing | No |

For learning purposes, implement `bridge` first — everything else is optional.

---

## Default Network Setup

On daemon startup, three networks are always created:

```
"bridge"  → driver: bridge  → docker0 interface
"host"    → driver: host    → no interface
"none"    → driver: null    → no interface
```

By default, new containers join the `bridge` network unless `NetworkMode` is set.

---

## Bridge Network Internals

The bridge driver creates a Linux bridge interface and uses `veth` pairs to connect containers.

### Creating the bridge

```
1. Create bridge interface:
   ip link add docker0 type bridge

2. Assign IP:
   ip addr add 172.17.0.1/16 dev docker0

3. Bring up:
   ip link set docker0 up

4. Enable IP forwarding on host:
   sysctl -w net.ipv4.ip_forward=1

5. Add iptables rules:
   # Allow container outbound traffic
   iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
   
   # Allow established connections back in
   iptables -A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   
   # Allow container-to-container traffic
   iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT
   
   # Allow outbound from containers
   iptables -A FORWARD -i docker0 ! -o docker0 -j ACCEPT
```

### IPAM (IP Address Management)

The built-in IPAM driver manages a pool of IPs within a subnet.

```
Pool state (per network):
{
    subnet:   "172.17.0.0/16"
    gateway:  "172.17.0.1"  (reserved)
    allocated: set{"172.17.0.1", "172.17.0.2", ...}
}

AllocateIP(network_id) → IP:
    for each IP in subnet:
        if IP not in allocated:
            allocated.add(IP)
            return IP
    error: subnet exhausted

ReleaseIP(network_id, ip):
    allocated.remove(ip)
```

### Connecting a container to the bridge

This happens during ContainerStart, in the OCI prestart hook or before the runtime call.

```
1. ALLOCATE IP
   ip = IPAM.AllocateIP(network_id)   → e.g. "172.17.0.2"

2. CREATE VETH PAIR
   ip link add vethXXXXXX type veth peer name eth0
   (one end stays on host, other end goes into container namespace)

3. ATTACH HOST END TO BRIDGE
   ip link set vethXXXXXX master docker0
   ip link set vethXXXXXX up

4. MOVE CONTAINER END INTO CONTAINER NETWORK NAMESPACE
   ip link set eth0 netns <container-pid>

5. CONFIGURE INSIDE CONTAINER NAMESPACE
   (run these in the container's netns via nsenter or clone)
   ip addr add 172.17.0.2/16 dev eth0
   ip link set eth0 up
   ip link set lo up
   ip route add default via 172.17.0.1

6. SET MAC ADDRESS (optional, for stability)
   ip link set eth0 address 02:42:ac:11:00:02

7. STORE IN ENDPOINT SETTINGS
   endpoint.ip_address = "172.17.0.2"
   endpoint.gateway    = "172.17.0.1"
   endpoint.mac        = "02:42:ac:11:00:02"
```

### Port publishing

When a container exposes a port (e.g. container port 80 → host port 8080):

```
Option A: iptables DNAT (preferred)
   iptables -t nat -A DOCKER ! -i docker0 -p tcp --dport 8080 \
       -j DNAT --to-destination 172.17.0.2:80
   iptables -A DOCKER -d 172.17.0.2/32 ! -i docker0 -o docker0 \
       -p tcp --dport 80 -j ACCEPT

Option B: userland proxy (docker-proxy)
   Launch: docker-proxy -proto tcp -host-ip 0.0.0.0 -host-port 8080 \
                        -container-ip 172.17.0.2 -container-port 80
   (A user-space process that forwards connections)
```

Both options are needed: iptables DNAT handles the common path, userland proxy handles edge cases (loopback hairpinning on some kernels).

---

## User-Defined Bridge Networks

When a user creates a network with `POST /networks/create`, the behavior is the same as `bridge` but with these additions:

- **Automatic DNS resolution**: containers on the same user-defined network can reach each other by container name or alias (e.g. `curl http://myapp/`).
- **Better isolation**: containers on different user-defined networks cannot communicate by default.
- **Configurable subnet**: user specifies the subnet/gateway in IPAM config.

### Internal DNS

The daemon runs a simple DNS server listening inside each user-defined network's namespace (or injects resolver config into containers):

- When container A asks for `myapp`, the DNS server looks up the endpoint in the network with name/alias `myapp` and returns its IP.
- `/etc/resolv.conf` inside the container points to this internal DNS server (e.g. `nameserver 127.0.0.11`).

---

## Network Lifecycle

### Create

```
function NetworkCreate(name, driver, ipam_config, options):
1. Validate name not in use
2. Instantiate driver (bridge: create linux bridge interface)
3. Initialize IPAM pool from ipam_config
4. Persist network config to {data_root}/network/files/{id}.json
5. Add to NetworkController
6. Publish event: type="network", action="create"
```

### Remove

```
function NetworkRemove(id):
1. Check no containers are currently attached (endpoint count == 0)
2. Remove iptables rules added for this network
3. Delete bridge interface: ip link del {bridge_name}
4. Delete {data_root}/network/files/{id}.json
5. Remove from NetworkController
6. Publish event: type="network", action="destroy"
```

### Connect container to network

```
function NetworkConnect(network_id, container_id, endpoint_config):
1. Get network, get container
2. If container is running:
   - Allocate IP from IPAM
   - Create veth pair
   - Configure inside container namespace
   Else:
   - Store endpoint config; wire up at ContainerStart
3. Update container.network_settings.networks[network.name]
4. Publish event: type="network", action="connect"
```

### Disconnect container from network

```
function NetworkDisconnect(network_id, container_id, force):
1. Get endpoint for this container in this network
2. If container is running:
   - Remove veth pair
   - Release IP back to IPAM
   - Remove iptables rules for this endpoint
3. Remove endpoint from container.network_settings
4. Publish event: type="network", action="disconnect"
```

---

## Sandbox

A "sandbox" is a network namespace. One sandbox corresponds to one container (or one pod in swarm mode).

```
Sandbox {
    id:          string        // usually same as container ID
    key:         string        // path to netns: /var/run/docker/netns/{id}
    endpoints:   []Endpoint    // veth interfaces attached to this sandbox
}
```

To create a sandbox (network namespace):
```sh
# Create named network namespace
ip netns add docker-{container_id}
# This creates: /var/run/netns/docker-{container_id}

# Or, at container start, the OCI runtime creates the netns automatically
# and passes the netns path via the runtime spec
```

---

## Network Namespace Paths

| Object | Path |
|--------|------|
| Named network namespace | `/var/run/netns/{name}` |
| Docker sandbox namespace | `/var/run/docker/netns/{id}` |
| Process namespace (by PID) | `/proc/{pid}/ns/net` |

To run a command in a specific network namespace:
```
nsenter --net=/var/run/docker/netns/{id} -- ip addr
```

---

## DNS Resolution Inside Containers

For user-defined networks:

1. The daemon embeds a DNS resolver at `127.0.0.11:53`
2. Container's `/etc/resolv.conf` is set to `nameserver 127.0.0.11`
3. iptables rules redirect DNS queries from containers to this resolver:
   ```
   iptables -t nat -A DOCKER_OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j DNAT --to 127.0.0.11:PORT
   iptables -t nat -A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j DNAT --to 127.0.0.11:PORT
   ```
4. The embedded resolver:
   - Answers queries for container names/aliases on the same network
   - Forwards unresolved queries to the upstream DNS (from daemon config or host `/etc/resolv.conf`)

For bridge (default) network, containers use the daemon's configured DNS (or host DNS), and cannot resolve each other by name.

---

## Host Networking Mode

When `NetworkMode: "host"`, the container joins the host's network namespace:
- No veth pair, no bridge
- Container sees all host interfaces
- Container can bind to host ports directly
- No isolation

Implementation: in the OCI spec, set `namespaces` to NOT include a network namespace entry. The process inherits the host's netns.

---

## Summary: What to Implement First

For a minimal working implementation:

1. Create `docker0` bridge at daemon start
2. IPAM: manage a simple IP pool for the subnet
3. On container start: create veth pair, connect to bridge, configure container namespace
4. iptables DNAT for port publishing
5. On container stop: tear down veth pair, release IP, remove iptables rules

DNS and user-defined networks can be added later.
