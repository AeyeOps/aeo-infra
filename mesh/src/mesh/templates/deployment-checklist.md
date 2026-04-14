# Deployment Checklist

## Planning

- Choose the Headscale FQDN.
- Choose the MagicDNS base domain.
- Decide whether public DNS recursion stays local or is moved to private resolvers.
- Decide whether one or multiple private DERP regions are needed.
- Define ACL and SSH policy before broad rollout.

## Server

- Provision Linux host with stable public IP.
- Publish DNS record for the Headscale FQDN.
- Install Headscale using the official package path.
- Apply the Headscale config.
- Enable embedded DERP.
- Remove the public DERP map.
- Disable logtail in Headscale.
- Install and configure the reverse proxy.
- Validate the HTTPS health endpoint.

## Clients

- Install official Tailscale clients.
- Disable early client logtail on every node.
- Join nodes to Headscale.
- Enable Tailscale SSH only where required.
- Validate MagicDNS and public DNS.
- Validate the DERP map on at least one node.

## Validation

- Confirm no public DERP map entries remain.
- Confirm no fresh public logtail traffic appears after a client restart.
- Confirm Tailscale SSH works where enabled.
- Confirm policy behaves as intended.
- Confirm Windows and WSL nodes behave as expected if endpoint VPN is also in use.
