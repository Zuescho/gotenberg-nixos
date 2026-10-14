# HTTPS (phase 2)

Phase 1 is plain HTTP and is the default. Turn on TLS only after the certificate files are on the VM.

Phase 2 terminates TLS in nginx on port 443. Gotenberg keeps listening on `127.0.0.1:3000` and does not see certificates. Port 80 on the same LAN address redirects to HTTPS. The firewall accepts 80 and 443 only from `iisSourceRanges` plus the host itself.

`services.nginx.sslProtocols` is `TLSv1.2 TLSv1.3`. The vhost repeats `ssl_protocols TLSv1.2 TLSv1.3` and disables session tickets. `recommendedTlsSettings` adds the current NixOS intermediate TLS profile.

The body limit stays 64 MB and the proxy read timeout stays at the API timeout (120 seconds), including for PDF uploads.

## Name on the certificate

The default name `gotenberg.dueren.de` matches a one-label wildcard `*.dueren.de`.

`gotenberg.intern.dueren.de` does not match `*.dueren.de`. Use that name only with a certificate that lists it, and set `fqdn` in [hosts/gotenberg/site.nix](../hosts/gotenberg/site.nix) to the same string. One option changes the host name, nginx `server_name`, and the URL the app uses.

## Files

| Path | Mode | Content |
| --- | --- | --- |
| `/var/lib/secrets` | `0700 root:root` | Parent directory, created when TLS is enabled |
| `/var/lib/secrets/gotenberg` | `0700 root:root` | This service |
| `/var/lib/secrets/gotenberg/fullchain.pem` | `0600 root:root` | Leaf certificate, then intermediates |
| `/var/lib/secrets/gotenberg/key.pem` | `0600 root:root` | Private key, unencrypted |

nginx’s master process starts as root and reads these files before workers drop privileges, so the key does not need to be readable by the `nginx` user.

Do not put the PEM files in the Git checkout or pass them as Nix paths. A Nix path is copied into `/nix/store`, which is world-readable. The module rejects a certificate path under `/nix/store`. `.gitignore` ignores `*.pem`, `*.key`, `*.pfx`, and `*.p12`.

## Convert a Windows PFX

Export the existing `*.dueren.de` certificate from the Windows certificate store, including the private key, as PKCS#12. Certificate Manager (`certlm.msc`) → Personal → the wildcard → All Tasks → Export. Include all certificates in the path if the wizard offers it.

```powershell
$pwd = Read-Host -AsSecureString "PFX password"
Get-ChildItem Cert:\LocalMachine\My |
  Where-Object { $_.Subject -like "*dueren.de*" -and $_.HasPrivateKey } |
  Select-Object -First 1 |
  ForEach-Object { Export-PfxCertificate -Cert $_ -FilePath .\wildcard.dueren.de.pfx -Password $pwd }
```

Copy the PFX to the VM with `scp`, then on the VM:

```bash
sudo install -d -m 0700 -o root -g root /var/lib/secrets /var/lib/secrets/gotenberg
umask 077
openssl pkcs12 -in wildcard.dueren.de.pfx -clcerts -nokeys -out cert.pem
openssl pkcs12 -in wildcard.dueren.de.pfx -nokeys -cacerts -out chain.pem
openssl pkcs12 -in wildcard.dueren.de.pfx -nocerts -nodes -out key.pem
# OpenSSL 3 also accepts -noenc instead of -nodes.
cat cert.pem chain.pem > fullchain.pem
sudo install -m 0600 -o root -g root fullchain.pem /var/lib/secrets/gotenberg/fullchain.pem
sudo install -m 0600 -o root -g root key.pem /var/lib/secrets/gotenberg/key.pem
shred -u wildcard.dueren.de.pfx cert.pem chain.pem fullchain.pem key.pem || rm -f wildcard.dueren.de.pfx cert.pem chain.pem fullchain.pem key.pem
```

If the PFX contains only the leaf, `chain.pem` is empty. Append the CA’s intermediate PEM to `fullchain.pem` yourself. Order is leaf, then intermediate. The root is optional.

Check the chain before switching clients:

```bash
sudo openssl x509 -in /var/lib/secrets/gotenberg/fullchain.pem -noout -subject -issuer -dates
sudo openssl verify -untrusted /var/lib/secrets/gotenberg/fullchain.pem /var/lib/secrets/gotenberg/fullchain.pem
```

A public CA chain verifies against the system trust store. An internal CA verifies only after that CA is trusted, which is expected on the VM.

## Switch the host on

In `hosts/gotenberg/site.nix` set:

```nix
httpProxy = true;
tls.enable = true;
```

`tls.enable` without the proxy is refused. Rebuild:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#gotenberg
```

nginx will not start if the PEM files are missing or unreadable. Fix the files and run `sudo systemctl restart nginx`.

```bash
curl --fail --silent --show-error https://gotenberg.dueren.de/health
openssl s_client -connect gotenberg.dueren.de:443 -servername gotenberg.dueren.de </dev/null
```

`s_client` should negotiate TLS 1.2 or 1.3 and show the wildcard (or the explicit name) in the certificate.

Port 80 answers `308` to `https://gotenberg.dueren.de/...` and is limited to the same source ranges.

## Base URL

```json
{
  "ERechnung": {
    "GotenbergBaseUrl": "https://gotenberg.dueren.de"
  }
}
```

No trailing slash. See the README for the phase 1 values.

## Trust on the IIS servers

A wildcard issued by a public CA that Windows already trusts needs nothing on the IIS hosts. The name in the URL must match the certificate. `https://gotenberg.dueren.de` matches `*.dueren.de`. An IP address in the URL will not.

An internal CA, or a self-signed certificate, must be imported on **each** IIS server. Import the issuing CA, not the leaf, into the Local Computer trusted-root store. .NET `HttpClient` uses that store.

```powershell
Import-Certificate -FilePath .\dueren-internal-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
```

Recycle the ERechnung application pool after the import so a failed chain is not cached. A chain error shows up as `AuthenticationException` / `RemoteCertificateChainErrors`. A wrong host name shows up as `RemoteCertificateNameMismatch`.

Confirm from the IIS server:

```powershell
Invoke-WebRequest -Uri https://gotenberg.dueren.de/health -UseBasicParsing
```

## Renewal

Replace the two PEM files in place. Paths stay the same, so Nix does not need a rebuild.

```bash
sudo install -m 0600 -o root -g root fullchain.pem /var/lib/secrets/gotenberg/fullchain.pem
sudo install -m 0600 -o root -g root key.pem /var/lib/secrets/gotenberg/key.pem
sudo systemctl reload nginx
curl --fail --silent --show-error https://gotenberg.dueren.de/health
```

Take a Hyper-V checkpoint before replacing a certificate that is already in use. Rollback of the files is restoring the previous PEM pair and reloading nginx. Rollback of the NixOS toggle is `tls.enable = false` and `nixos-rebuild switch`, or `nixos-rebuild switch --rollback` if that was the previous generation.

## sops-nix or agenix

The default is files on disk. Use sops-nix or agenix when the key should live in the repository in encrypted form. Do not add either input until you have a key; the host builds without them.

Outline for sops-nix, not wired into this flake:

```nix
# inputs.sops-nix.url = "github:Mic92/sops-nix";
# imports = [ inputs.sops-nix.nixosModules.sops ];
sops.defaultSopsFile = ./secrets.yaml;
sops.age.keyFile = "/var/lib/secrets/age.key";
sops.secrets."gotenberg/fullchain.pem" = {
  owner = "root";
  mode = "0600";
  path = "/var/lib/secrets/gotenberg/fullchain.pem";
};
sops.secrets."gotenberg/key.pem" = {
  owner = "root";
  mode = "0600";
  path = "/var/lib/secrets/gotenberg/key.pem";
};
```

agenix writes the same paths from `age.secrets`. Keep `services.gotenberg-lan.proxy.tls.certificate` and `.key` pointed at those paths. The plaintext still must not appear in Git.
